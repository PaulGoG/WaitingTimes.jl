"""
Pipeline orchestration: prepare a series from a configuration, generate the
collection of waiting-time distributions with resume and reference checks, and
validate kernels against the reference kernel.
"""
module Orchestrator

using Dates: UTC, now
using DocStringExtensions: TYPEDFIELDS, TYPEDSIGNATURES
using Logging: @info, @warn
using ProgressMeter: finish!, next!
using Random: MersenneTwister, shuffle
using TimerOutputs: TimerOutputs, TimerOutput, @timeit, ncalls
using ..WaitingTimes: WaitingTimes, AbstractSearch, DeviceSearch, FenwickSweep,
                      GuardedSearch,
                      NaiveSearch,
                      QuantizedSeries, SegmentTreeSearch, StreamingSearch, Threshold,
                      WaitingTimeDistribution, censoring_counts, class_columns, classify,
                      empirical_distribution, format_threshold, gap_entries, nsamples,
                      record_length, sampling_step, scan_work, segment_lengths, support,
                      waiting_times, waiting_times!, with_step, workspace
using ..Config: Settings, load_settings, threshold_decimals, threshold_list
using ..Provenance: active_manifest, artefact_id, backup_existing!, content_hash,
                    file_sha256, git_state, hardware_fingerprint, package_identity,
                    read_toml, record_to_dict, session_id, slugify, source_summary,
                    toml_ready, write_hardware_fingerprint, write_toml
using ..Preprocessing: RawSeries, apply_steps, index_series, quantized_series,
                       read_gap_intervals, read_series, resolution_digits, suggest_digits
using ..Storage: MANIFEST_FILE, SOURCE_FILE, censoring_path, partition_path, read_index,
                 write_catalog,
                 write_censoring, write_collection_readme, write_distribution,
                 write_index, write_series_files, write_summary, write_waiting_times
using ..Monitoring: run_progress, with_run_logging
using ..Backends: backend_name, device_fingerprint
using KernelAbstractions: CPU

export CollectionHandle, run_pipeline, prepare, generate, validate, make_kernel,
       estimate_memory_bytes, dataset_descriptor

"provenance schema written into metadata files"
const SCHEMA = "waitingtimes-provenance/3"

"""
    CollectionHandle

Result of a generation run: identifiers, directory and what the session did.

$(TYPEDFIELDS)
"""
struct CollectionHandle
    "collection identifier"
    id::String
    "collection directory"
    dir::String
    "series identifier"
    series_id::String
    "dataset identifier"
    dataset_id::String
    "session identifier"
    session::String
    "thresholds computed in this session (fixed-decimal strings)"
    computed::Vector{String}
    "thresholds skipped because partitions existed"
    skipped::Vector{String}
    "reference check records"
    reference_checks::Vector{Dict{String, Any}}
end

# --- dataset descriptors -----------------------------------------------------

"""
$(TYPEDSIGNATURES)

Dataset descriptor named by `[input].dataset`, searched in `<config dir>/datasets/`
and in the package's `configs/datasets/`; `nothing` when the setting is empty.
"""
function dataset_descriptor(settings::Settings)
    isempty(settings.dataset) && return nothing
    name = settings.dataset * ".toml"
    for dir in (joinpath(settings.config_dir, "datasets"),
        joinpath(WaitingTimes.PACKAGE_ROOT, "configs", "datasets"))
        path = joinpath(dir, name)
        isfile(path) && return read_toml(path)
    end
    throw(ArgumentError("dataset descriptor $(settings.dataset) not found"))
end

"""
$(TYPEDSIGNATURES)

Source descriptor named by `[input].source_descriptor` as `(path, sha256,
descriptor, summary)`: the parsed table and its normalised identity
([`source_summary`](@ref WaitingTimes.Provenance.source_summary)); `nothing`
when the setting is empty. Any TOML file is accepted and recorded verbatim; a
producer version below the minimum the package reads is reported with a
warning and recorded, a descriptor without code identity with a note.
"""
function source_record(settings::Settings)
    isempty(settings.source_descriptor) && return nothing
    path = settings.source_descriptor
    descriptor = read_toml(path)
    summary = source_summary(descriptor)
    summary["compat_checked"] && !summary["compat_satisfied"] &&
        @warn "[input] source_descriptor names a producer version this version of WaitingTimes does not read" producer=summary["producer"] version=summary["producer_version"] minimum=summary["producer_compat"]
    summary["identity"] ||
        @info "[input] source_descriptor records no git_tree_sha1; the producer's code is not identified" producer=summary["producer"]
    return (path = path, sha256 = file_sha256(path), descriptor = descriptor,
        summary = summary)
end

# --- kernels -----------------------------------------------------------------

"""
$(TYPEDSIGNATURES)

Search kernel named by `[algorithm].search`; `:device` is served by the
device extension when a backend is loaded.
"""
function make_kernel(settings::Settings)
    s = settings.search
    s === :naive && return NaiveSearch(; chunk_size = settings.chunk_size)
    s === :guarded && return GuardedSearch(; chunk_size = settings.chunk_size)
    s === :segment_tree && return SegmentTreeSearch(; chunk_size = settings.chunk_size)
    s === :fenwick_sweep && return FenwickSweep()
    s === :streaming && return StreamingSearch()
    s === :device && return WaitingTimes.device_search(settings.backend)
    throw(ArgumentError("unknown search $s"))
end

function make_reference_kernel(settings::Settings)
    settings.reference_kernel === :naive ? NaiveSearch(; chunk_size = settings.chunk_size) :
    settings.reference_kernel === :guarded ?
    GuardedSearch(; chunk_size = settings.chunk_size) :
    WaitingTimes.device_search(settings.backend)
end

kernel_name(alg::AbstractSearch) = lowercase(string(nameof(typeof(alg))))

"""
$(TYPEDSIGNATURES)

Host memory estimate in bytes for one threshold of `s` with `alg`: series,
result vector and workspace.
"""
function estimate_memory_bytes(s::QuantizedSeries{Tv, Tt}, alg::AbstractSearch) where {
        Tv, Tt}
    N = length(s)
    base = N * (sizeof(Tv) + 2 * sizeof(Tt)) + 8 * length(s.gaps)
    ws = alg isa SegmentTreeSearch ? 2 * max(1, nextpow(2, N)) * sizeof(Tv) :
         alg isa GuardedSearch ? N * sizeof(Tv) :
         alg isa FenwickSweep ? N * 8 + length(unique(s.values)) * (8 + sizeof(Tv)) :
         alg isa StreamingSearch ? N * (sizeof(Tv) + 8 + sizeof(Tt)) : 0
    return base + ws + 2 * N   # classification bytes
end

# --- prepare -----------------------------------------------------------------

function step_tag(step::AbstractDict)
    op = String(step["op"])
    if op == "trailing_mean_fluctuations"
        denominator = String(get(step, "denominator", "mean"))
        suffix = denominator == "mean" ? "" : denominator == "scale" ? "scaled" : "abs"
        return "trailing" * string(step["window"]) * suffix
    end
    op == "round" ? "round" * string(step["digits"]) :
    op == "centered_moving_average" ? "cma" * string(step["window"]) :
    op == "clip_quantile" ? "clip" * string(step["q"]) :
    op == "clip_sigma" ? "sigma" * string(get(step, "k", 3)) :
    op == "clip_extremes" ? "prune" * string(get(step, "fraction", 0.004)) :
    op == "log_returns" ? "logret" :
    op == "log_levels" ? "loglevels" :
    op == "differences" ? "diff" :
    op == "select_range" ? "range" :
    op == "exclude_intervals" ? "cut" :
    op == "collapse_ties" ? "ties" : op
end

"""
$(TYPEDSIGNATURES)

Read, preprocess and quantise the series described by `settings`. Returns the
series, on the configured time axis, and a named tuple of identifiers and
slugs together with what the collection stores beside the series: the row
ordinal (`rows`) and the original clock (`time_original`) of every
observation, the gaps of the original clock with their kinds
(`gaps_original`), and that clock's time unit and epoch.
"""
function prepare(settings::Settings)
    descriptor = dataset_descriptor(settings)
    rs = read_series(settings.input_path; format = settings.input_format,
        value_column = settings.value_column, time_column = settings.time_column,
        time_unit = settings.time_unit, time_format = settings.time_format,
        epoch_unit = settings.epoch_unit, delimiter = settings.delimiter,
        header = settings.header, missing_policy = settings.missing_policy,
        tie_policy = settings.tie_policy)
    if descriptor !== nothing && haskey(descriptor, "sha256") &&
       !isempty(descriptor["sha256"])
        descriptor["sha256"] == rs.record.source_sha256 || throw(ArgumentError(
            "input file checksum $(rs.record.source_sha256) differs from the descriptor's $(descriptor["sha256"])",
        ))
    end
    rs = apply_steps(rs, settings.steps)
    digits, rs = resolve_digits(settings, rs)
    resolution = resolution_digits(rs)
    resolution === nothing || resolution <= digits ||
        @warn "[quantization] digits is below the recorded resolution of the prepared series; quantisation merges distinct values" digits resolution
    declared = isempty(settings.declared_gaps) ? Tuple{Int64, Int64}[] :
               read_gap_intervals(settings.declared_gaps)
    s_clock = quantized_series(rs, digits; detect = settings.gap_detect,
        cadence = settings.gap_cadence, threshold = settings.gap_threshold, declared = declared)
    s = settings.time_axis === :index ?
        index_series(rs, s_clock; detect = settings.gap_detect !== :none) : s_clock

    source = source_record(settings)
    dataset_identity = Dict{String, Any}("sha256" => rs.record.source_sha256,
        "value_column" => settings.value_column, "time_column" => settings.time_column)
    source === nothing || (dataset_identity["source_sha256"] = source.sha256)
    dataset_slug = descriptor === nothing ?
                   slugify(splitext(basename(settings.input_path))[1] * "-" *
                           string(settings.value_column)) :
                   slugify(get(descriptor, "slug", settings.dataset))
    dataset_id = artefact_id("dataset", dataset_slug, dataset_identity)
    series_identity = Dict{String, Any}("dataset" => dataset_id,
        "time_unit" => settings.time_unit, "epoch_unit" => settings.epoch_unit,
        "missing_policy" => settings.missing_policy, "tie_policy" => settings.tie_policy,
        "steps" => settings.steps, "digits" => digits,
        "declared_gaps_sha256" =>
            isempty(settings.declared_gaps) ? "" :
            file_sha256(settings.declared_gaps),
        "gap_detect" => settings.gap_detect, "gap_cadence" => settings.gap_cadence,
        "gap_threshold" => settings.gap_threshold)
    settings.time_axis === :elapsed || (series_identity["time_axis"] = settings.time_axis)
    series_slug = isempty(settings.steps) ? dataset_slug :
                  dataset_slug * "+" * join(step_tag.(settings.steps), "+")
    series_id = artefact_id("series", series_slug, series_identity)
    ids = (dataset_id = dataset_id, dataset_slug = dataset_slug,
        dataset_identity = dataset_identity,
        series_id = series_id, series_slug = series_slug, series_identity = series_identity,
        descriptor = descriptor, source = source, raw = rs,
        time_axis = settings.time_axis, rows = findall(!ismissing, rs.values),
        time_original = s_clock.times, gaps_original = gap_entries(s_clock),
        time_unit_original = rs.time_unit, epoch = rs.epoch)
    return s, ids
end

"""
$(TYPEDSIGNATURES)

The `digits` of the run: the configured value, or for `digits = "auto"` the
choice of [`suggest_digits`](@ref WaitingTimes.Preprocessing.suggest_digits)
under the threshold grid and the `auto_*` keys, recorded in the preparation
record of `rs` and logged. An automatic choice that meets the tolerance at no
grid up to `auto_max_digits` is an error. Returns the digits and `rs`, with
the choice recorded when it was automatic.
"""
function resolve_digits(settings::Settings, rs)
    settings.digits === nothing || return settings.digits, rs
    choice = suggest_digits(rs; min_digits = threshold_decimals(settings),
        tolerance = settings.auto_tolerance, step_ratio = settings.auto_step_ratio,
        max_digits = settings.auto_max_digits)
    choice.rule === :max_digits && throw(ArgumentError(
        "[quantization] digits = \"auto\" meets auto_tolerance = $(settings.auto_tolerance) at no grid up to auto_max_digits = $(settings.auto_max_digits) (last distance $(choice.ks)); raise auto_max_digits or set digits",
    ))
    summary = Dict{String, Any}("digits" => choice.digits, "rule" => String(choice.rule))
    for key in (:resolution, :dispersion_digits, :increment_scale, :ks)
        value = getfield(choice, key)
        value === nothing || (summary[String(key)] = value)
    end
    record = with_step(rs.record, :suggest_digits,
        Dict{String, Any}("min_digits" => choice.min_digits,
            "tolerance" => settings.auto_tolerance, "step_ratio" =>
                settings.auto_step_ratio,
            "max_digits" => settings.auto_max_digits),
        summary)
    @info "[quantization] digits = \"auto\"" digits=choice.digits rule=choice.rule ks=choice.ks
    return choice.digits, RawSeries(rs.values, rs.times, rs.time_unit, rs.epoch, record)
end

# --- generate ----------------------------------------------------------------

function collection_identity(ids, settings::Settings)
    return Dict{String, Any}("series" => ids.series_id, "mode" => String(settings.mode))
end

"""
$(TYPEDSIGNATURES)

The description of the prepared series written to `series.toml` and into the
`[series]` section of `metadata.toml`: record, grid, time axis and the clock
of the input, the record structure (sampling step, record length, segments)
and the number of gaps of each kind.
"""
function series_summary(ids, s::QuantizedSeries)
    kinds = Dict{String, Any}()
    for k in s.gap_kinds
        kinds[k] = get(kinds, k, 0) + 1
    end
    out = Dict{String, Any}("id" => ids.series_id, "record" => record_to_dict(s.record),
        "digits" => s.digits, "value_type" => string(eltype(s.values)),
        "time_axis" => String(ids.time_axis), "time_unit" => String(s.time_unit),
        "time_unit_original" => String(ids.time_unit_original),
        "n_observations" => length(s), "n_observed" => length(s),
        "n_gaps" => length(s.gaps), "gap_kinds" => kinds,
        "sampling_step" => Int(sampling_step(s)), "record_length" => record_length(s),
        "n_segments" => length(segment_lengths(s)))
    s.epoch === nothing || (out["epoch"] = s.epoch)
    ids.epoch === nothing || (out["epoch_original"] = ids.epoch)
    return out
end

function initial_metadata(id, ids, settings::Settings, s::QuantizedSeries)
    series = series_summary(ids, s)
    series["slug"] = ids.series_slug
    series["identity"] = ids.series_identity
    meta = Dict{String, Any}(
        "schema" => SCHEMA,
        "artefact" => Dict{String, Any}("id" => id, "kind" => "collection",
            "created" => now(UTC), "parents" => [ids.series_id]),
        "identity" => collection_identity(ids, settings),
        "series" => series,
        "dataset" => Dict{String, Any}("id" => ids.dataset_id, "slug" => ids.dataset_slug,
            "identity" => ids.dataset_identity,
            "descriptor" =>
                ids.descriptor === nothing ? Dict{String, Any}() : ids.descriptor),
        "sessions" => Any[]
    )
    if ids.source !== nothing
        meta["source"] = merge(
            Dict{String, Any}("file" => SOURCE_FILE,
                "sha256" => ids.source.sha256, "descriptor" => ids.source.descriptor),
            ids.source.summary)
    end
    return meta
end

function partition_entry(
        δ::Threshold, d::WaitingTimeDistribution, file, sha, session, seconds, kernel)
    sup = support(d)
    K = nsamples(d)
    expanded_median = K == 0 ? missing : weighted_median(sup, d.counts)
    return Dict{String, Any}(
        "delta" => format_threshold(δ), "file" => file, "sha256" => sha, "session" =>
            session,
        "mode" => String(d.mode), "n_candidates" => d.n_candidates, "n_exact" => d.n_exact,
        "n_gap_crossing" => d.n_gap_crossing, "n_right_censored" => d.n_right_censored,
        "n_waiting" => K, "tau_min" => K == 0 ? missing : first(sup),
        "tau_max" => K == 0 ? missing : last(sup),
        "tau_mean" => K == 0 ? missing : sum(Float64.(sup) .* d.counts) / K,
        "tau_median" => expanded_median, "seconds" => seconds, "kernel" => kernel)
end

function weighted_median(values, weights)
    half = sum(weights) / 2
    acc = 0
    for (v, w) in zip(values, weights)
        acc += w
        acc >= half && return v
    end
    return last(values)
end

function catalog_row(entry, id, series_slug)
    Dict{String, Any}(
        "id" => id, "kind" => "distribution", "series" => series_slug, "delta" =>
            entry["delta"],
        "mode" => entry["mode"], "file" => entry["file"], "sha256" => entry["sha256"],
        "session" => entry["session"], "n_waiting" => entry["n_waiting"],
        "n_right_censored" => entry["n_right_censored"])
end

"""
$(TYPEDSIGNATURES)

Generate (or extend) the collection of waiting-time distributions described
by `settings`: prepare the series, compute every configured threshold not yet
present, write partitions, run reference checks, and record the session.
"""
function generate(settings::Settings)
    s, ids = prepare(settings)
    id = artefact_id("collection", ids.series_slug, collection_identity(ids, settings))
    dir = joinpath(settings.output_root, id)
    mkpath(joinpath(dir, "distributions"))
    mkpath(joinpath(dir, "sessions"))
    git = git_state(WaitingTimes.PACKAGE_ROOT)
    identity = package_identity()
    code = isempty(identity["git_commit"]) ? identity["git_tree_sha1"] :
           identity["git_commit"]
    session = session_id(code)
    manifest = active_manifest()
    timer = TimerOutput()
    computed = String[]
    skipped = String[]
    checks = Dict{String, Any}[]
    with_run_logging(joinpath(dir, "run.log"); level = settings.log_level) do
        @info "collection" id dir session series=ids.series_id observations=length(s) gaps=length(s.gaps)
        config_snapshot = joinpath(dir, "config.toml")
        isfile(config_snapshot) || write_toml(config_snapshot, settings.raw)
        write_toml(joinpath(dir, "sessions", session * ".config.toml"), settings.raw)
        ids.source === nothing || isfile(joinpath(dir, SOURCE_FILE)) ||
            cp(ids.source.path, joinpath(dir, SOURCE_FILE))
        meta_path = joinpath(dir, "metadata.toml")
        meta = isfile(meta_path) ? read_toml(meta_path) :
               initial_metadata(id, ids, settings, s)
        toml_ready(meta["identity"]) == toml_ready(collection_identity(ids, settings)) ||
            throw(ArgumentError(
                "directory $dir holds a collection with a different identity",
            ))
        isfile(joinpath(dir, "gaps.csv")) || @timeit timer "series files" begin
            write_series_files(dir, s, settings.output_format; rows = ids.rows,
                time_original = ids.time_original,
                gaps_original = ids.time_axis === :index ? ids.gaps_original : nothing)
            write_toml(joinpath(dir, "series.toml"), series_summary(ids, s))
        end

        alg = make_kernel(settings)
        bytes = estimate_memory_bytes(s, alg)
        limit = settings.max_ram_gb * 2^30
        bytes <= limit || throw(ArgumentError(
            "estimated memory $(round(bytes / 2^30; digits = 2)) GiB exceeds [limits] max_ram_gb = $(settings.max_ram_gb)",
        ))
        if alg isa DeviceSearch && !(alg.backend isa CPU)
            vram = length(s) * (2 * sizeof(eltype(s.values)) + 2 * sizeof(eltype(s.times)))
            vram <= settings.max_vram_gb * 2^30 || throw(ArgumentError(
                "estimated device memory $(round(vram / 2^30; digits = 2)) GiB exceeds [limits] max_vram_gb = $(settings.max_vram_gb)",
            ))
            @info "device backend" name=backend_name(alg.backend) device_gib=round(vram/2^30; digits = 3)
        end
        thresholds = threshold_list(settings, s)
        entries = read_index(dir)
        existing = Dict(e["delta"] => e for e in entries)
        @info "thresholds" total=length(thresholds) existing=length(existing) kernel=kernel_name(alg) memory_gib=round(
            bytes/2^30; digits = 3)
        ws = @timeit timer "workspace" workspace(alg, s)
        todo = eltype(thresholds)[]
        for δ in thresholds
            key = format_threshold(δ)
            if haskey(existing, key) && !settings.overwrite
                push!(skipped, key)
            else
                push!(todo, δ)
            end
        end
        # The Fenwick sweep serves every threshold of a batch in one pass; the
        # batch is as large as the memory bound leaves room for.
        Tt = eltype(s.times)
        batch = alg isa FenwickSweep ?
                clamp(floor(Int, (limit - bytes) / (length(s) * sizeof(Tt))), 1,
            max(1, length(todo))) : 1
        τs = [Vector{Tt}(undef, length(s)) for _ in 1:min(batch, max(1, length(todo)))]
        progress = run_progress(length(thresholds))
        foreach(_ -> next!(progress), skipped)
        for chunk in Iterators.partition(todo, batch)
            outs = τs[1:length(chunk)]
            search_seconds = @elapsed @timeit timer "search" begin
                if alg isa FenwickSweep
                    waiting_times!(outs, s, collect(chunk), alg; workspace = ws)
                else
                    waiting_times!(only(outs), s, only(chunk), alg; workspace = ws)
                end
            end
            for (δ, τ) in zip(chunk, outs)
                key = format_threshold(δ)
                seconds = search_seconds / length(chunk) + @elapsed begin
                    class, lower, upper = @timeit timer "distribution" classify(τ, s)
                    d = @timeit timer "distribution" empirical_distribution(τ, δ, s, class;
                        mode = settings.mode)
                    exact, gap_crossing = class_columns(τ, class, d)
                    bounds, bound_counts = censoring_counts(class, lower)
                end
                path = partition_path(dir, δ, settings.output_format)
                cens_path = censoring_path(dir, δ, settings.output_format)
                if settings.overwrite
                    backup_existing!(path)
                    backup_existing!(cens_path)
                end
                metadata = Dict("schema" => SCHEMA, "collection" => id, "delta" => key,
                    "session" => session, "mode" => String(settings.mode))
                sha = @timeit timer "write" write_distribution(path, d,
                    settings.output_format; metadata = metadata, exact = exact,
                    gap_crossing = gap_crossing)
                cens_sha = @timeit timer "write" write_censoring(cens_path, bounds,
                    bound_counts, settings.output_format; metadata = metadata)
                if settings.store_waiting_times
                    wt_path = joinpath(dir, "waiting_times",
                        "delta=" * key * "." *
                        (settings.output_format === :arrow ? "arrow" : "csv"))
                    settings.overwrite && backup_existing!(wt_path)
                    @timeit timer "write" write_waiting_times(
                        wt_path, τ, class, lower, upper,
                        settings.output_format; metadata = metadata)
                end
                entry = partition_entry(δ, d, relpath(path, dir), sha, session, seconds,
                    kernel_name(alg))
                entry["censoring_file"] = relpath(cens_path, dir)
                entry["censoring_sha256"] = cens_sha
                existing[key] = entry
                push!(computed, key)
                next!(progress)
            end
        end
        finish!(progress)

        if settings.reference_checks > 0 && !isempty(computed)
            checks = reference_check!(timer, s, thresholds, computed, alg, ws, settings)
        end

        entries = sort!(collect(values(existing)); by = e -> parse(Float64, e["delta"]))
        write_index(dir, entries)
        write_summary(dir, entries)
        write_catalog(dir, [catalog_row(e, id, ids.series_slug) for e in entries])

        manifest_sha = ""
        if manifest === nothing
            @warn "no resolved manifest for the active environment; the session records no dependency versions"
        else
            cp(manifest, joinpath(dir, "sessions", session * ".manifest.toml"); force = true)
            cp(manifest, joinpath(dir, MANIFEST_FILE); force = true)
            manifest_sha = file_sha256(manifest)
        end
        hardware = hardware_fingerprint()
        device_report = alg isa DeviceSearch ? device_fingerprint(alg.backend) : ""
        write_hardware_fingerprint(joinpath(dir, "sessions", session * ".hardware.txt");
            device_report = device_report)
        cp(joinpath(dir, "sessions", session * ".hardware.txt"), joinpath(dir, "hardware.txt"); force = true)
        record = Dict{String, Any}("id" => session, "created" => now(UTC),
            "kernel" => kernel_name(alg),
            "backend" =>
                alg isa DeviceSearch ? backend_name(alg.backend) : String(settings.backend),
            "threads" => Threads.nthreads(), "chunk_size" => settings.chunk_size,
            "package_version" => string(pkgversion(WaitingTimes)), "git" => git,
            "producer" => identity, "manifest_sha256" => manifest_sha,
            "julia" => string(VERSION), "hardware" => hardware,
            "config_hash" => content_hash(settings.raw),
            "deltas_computed" => computed, "deltas_skipped" => skipped,
            "reference_checks" => checks, "timings" => timings(timer),
            "memory_estimate_bytes" => bytes)
        write_toml(joinpath(dir, "sessions", session * ".toml"), record)
        meta["producer"] = merge(
            Dict{String, Any}("name" => "WaitingTimes",
                "version" => string(pkgversion(WaitingTimes)), "session" => session),
            identity)
        meta["environment"] = Dict{String, Any}("manifest_sha256" => manifest_sha,
            "manifest_file" => manifest === nothing ? "" : MANIFEST_FILE,
            "julia" => string(VERSION), "session" => session)
        push!(meta["sessions"],
            Dict{String, Any}("id" => session, "created" => record["created"],
                "kernel" => record["kernel"], "git" => git, "n_computed" =>
                    length(computed),
                "n_skipped" => length(skipped), "n_reference_checks" => length(checks)))
        write_toml(meta_path, meta)
        write_collection_readme(dir, meta, entries, settings.output_format)
        @info "session complete" computed=length(computed) skipped=length(skipped) reference_checks=length(checks) seconds=round(
            TimerOutputs.tottime(timer)/1e9; digits = 2)
    end
    return CollectionHandle(
        id, dir, ids.series_id, ids.dataset_id, session, computed, skipped, checks)
end

function timings(timer::TimerOutput)
    out = Dict{String, Any}()
    for name in keys(timer.inner_timers)
        section = timer[name]
        out[name] = Dict{String, Any}("seconds" => TimerOutputs.time(section) / 1e9,
            "calls" => ncalls(section))
    end
    out["total_seconds"] = TimerOutputs.tottime(timer) / 1e9
    return out
end

"""
$(TYPEDSIGNATURES)

Recompute `settings.reference_checks` thresholds among those just computed with
the reference kernel (always including the largest) and compare exactly. A
disagreement raises after being recorded; a check whose scan work
([`scan_work`](@ref), in element comparisons) exceeds
`[limits].max_reference_work` is skipped with a warning.
"""
function reference_check!(timer, s, thresholds, computed, alg, ws, settings::Settings)
    by_key = Dict(format_threshold(δ) => δ for δ in thresholds)
    keys_ = sort(computed; by = k -> parse(Float64, k))
    chosen = [last(keys_)]
    rest = keys_[1:(end - 1)]
    rng = MersenneTwister(settings.seed)
    append!(chosen, first(shuffle(rng, rest), max(0, settings.reference_checks - 1)))
    reference = make_reference_kernel(settings)
    checks = Dict{String, Any}[]
    τ_fast = Vector{eltype(s.times)}(undef, length(s))
    for key in chosen
        δ = by_key[key]
        waiting_times!(τ_fast, s, δ, alg; workspace = ws)
        work = Float64(scan_work(τ_fast, s; guarded = !(reference isa NaiveSearch)))
        if work > settings.max_reference_work
            @warn "reference check skipped: work bound exceeds [limits] max_reference_work" delta = key work
            push!(checks,
                Dict{String, Any}("delta" => key, "kernel" => kernel_name(reference),
                    "skipped" => true, "work" => work))
            continue
        end
        seconds = @elapsed τ_reference = @timeit timer "reference" waiting_times(s, δ, reference)
        equal = τ_reference == τ_fast
        push!(checks,
            Dict{String, Any}("delta" => key, "kernel" => kernel_name(reference),
                "equal" => equal, "seconds" => seconds, "work" => work, "skipped" => false))
        @info "reference check" delta=key kernel=kernel_name(reference) equal seconds=round(seconds; digits = 3)
        equal ||
            error("reference disagreement at delta = $key between $(kernel_name(alg)) and $(kernel_name(reference))")
    end
    return checks
end

"""
$(TYPEDSIGNATURES)

Compare the configured kernel with the reference kernel on `deltas` (defaults to the
largest configured threshold and `reference_checks - 1` random ones). Returns a
report dictionary; disagreements are reported, not thrown.
"""
function validate(settings::Settings; deltas = nothing)
    s, ids = prepare(settings)
    alg = make_kernel(settings)
    reference = make_reference_kernel(settings)
    ws = workspace(alg, s)
    thresholds = deltas === nothing ? threshold_list(settings, s) :
                 Threshold{eltype(s.values)}[WaitingTimes.threshold(δ, s) for δ in deltas]
    if deltas === nothing
        rng = MersenneTwister(settings.seed)
        chosen = [last(thresholds)]
        append!(chosen, first(shuffle(rng, thresholds[1:(end - 1)]), max(0, settings.reference_checks -
                                                                            1)))
        thresholds = chosen
    end
    results = Dict{String, Any}[]
    τ_fast = Vector{eltype(s.times)}(undef, length(s))
    for δ in thresholds
        waiting_times!(τ_fast, s, δ, alg; workspace = ws)
        seconds = @elapsed τ_reference = waiting_times(s, δ, reference)
        push!(results,
            Dict{String, Any}(
                "delta" => format_threshold(δ), "equal" => τ_reference == τ_fast,
                "seconds" => seconds,
                "work" =>
                    Float64(scan_work(τ_fast, s; guarded = !(reference isa NaiveSearch))),
                "n_differences" => count(τ_reference .!= τ_fast)))
    end
    return Dict{String, Any}("series" => ids.series_id, "kernel" => kernel_name(alg),
        "reference_kernel" => kernel_name(reference), "all_equal" =>
            all(r -> r["equal"], results),
        "results" => results)
end

"""
$(TYPEDSIGNATURES)

Load the configuration at `config_path` (output root overridden by
`output_dir` when given) and run [`generate`](@ref).
"""
function run_pipeline(config_path::AbstractString; output_dir = nothing)
    return generate(load_settings(config_path; output_dir = output_dir))
end

end # module
