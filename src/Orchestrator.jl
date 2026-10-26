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
using Random: AbstractRNG, MersenneTwister, shuffle
using TimerOutputs: TimerOutputs, TimerOutput, @timeit, ncalls
using ..WaitingTimes: WaitingTimes, AbstractSearch, DeviceSearch, FenwickSweep,
                      GuardedSearch,
                      NaiveSearch,
                      QuantizedSeries, SegmentTreeSearch, StreamingSearch, Threshold,
                      WaitingTimeDistribution, censoring_counts, class_columns, classify,
                      empirical_distribution, format_threshold, gap_entries, nsamples,
                      parse_threshold, record_length, sampling_step, scan_work,
                      segment_lengths, support, waiting_times!, with_step, workspace,
                      workspace_bytes
using ..Config: Settings, load_settings, step_tag, threshold_decimals, threshold_list
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
using ..Backends: backend_name, device_fingerprint, host_backend, reclaim_device_memory!

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

Search kernel named by `[algorithm].search`; `:device` is a `DeviceSearch` on
`[algorithm].backend`, which needs KernelAbstractions loaded in the session
(`:none` for its CPU backend; a GPU backend also needs its package loaded).
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

Host memory estimate in bytes for one threshold of `s` with `alg`: the series
arrays (values and times) and the result vector, ``N (\\mathrm{sizeof}(T_v) +
2\\,\\mathrm{sizeof}(T_t))``, and 8 bytes per gap; the workspace of `alg`
(`workspace_bytes`); and the transients of one threshold
(`transient_bytes`), which include the dense waiting-time table when
`store_waiting_times` is set.
"""
function estimate_memory_bytes(s::QuantizedSeries{Tv, Tt}, alg::AbstractSearch;
        store_waiting_times::Bool = false) where {Tv, Tt}
    N = length(s)
    base = N * (sizeof(Tv) + 2 * sizeof(Tt)) + 8 * length(s.gaps)
    return base + workspace_bytes(alg, s) +
           transient_bytes(s; store_waiting_times = store_waiting_times)
end

"""
$(TYPEDSIGNATURES)

Bytes allocated per threshold after the search, as an upper bound with a
support of at most ``N`` values: `classify` (classes, ``N`` bytes; lower and
upper bounds, ``2N\\,\\mathrm{sizeof}(T_t)``; gap starts, 8 bytes per gap),
`empirical_distribution` (the sorted sample and the support,
``2N\\,\\mathrm{sizeof}(T_t)``; counts, probability mass and cumulative
distribution, ``24N``), `class_columns` (``16N``), `censoring_counts` (the
censored lower bounds and their distinct values, ``2N\\,\\mathrm{sizeof}(T_t)``;
their counts, ``8N``) and, when `store_waiting_times` is set, the dense table
of `tau`, `class`, `lower` and `upper`, ``N (1 + 3\\,\\mathrm{sizeof}(T_t))``,
about ``25N``.
"""
function transient_bytes(s::QuantizedSeries{Tv, Tt};
        store_waiting_times::Bool = false) where {Tv, Tt}
    N = length(s)
    classification = N + 2N * sizeof(Tt) + 8 * length(s.gaps)
    distribution = 2N * sizeof(Tt) + 3 * 8N
    columns = 2 * 8N
    censoring = 2N * sizeof(Tt) + 8N
    dense = store_waiting_times ? N * (1 + 3 * sizeof(Tt)) : 0
    return classification + distribution + columns + censoring + dense
end

# --- prepare -----------------------------------------------------------------

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

Rewrite `index.toml`, `summary.csv` and `catalog.csv` of the collection `id`
in `dir` from the partition entries `existing` (keyed by threshold string),
sorted on the grid integer of the threshold for a grid of `digits` decimals.
Returns the sorted entries.
"""
function write_index_files(dir::AbstractString, existing::AbstractDict,
        id::AbstractString, series_slug::AbstractString, digits::Integer)
    entries = sort!(collect(values(existing));
        by = e -> parse_threshold(e["delta"], digits).d)
    write_index(dir, entries)
    write_summary(dir, entries)
    write_catalog(dir, [catalog_row(e, id, series_slug) for e in entries])
    return entries
end

"""
$(TYPEDSIGNATURES)

Record of the session `session` written to `sessions/<id>.toml`: identifier,
creation time, kernel and backend of `alg`, threads, chunk size, package
version, git state, code identity, Julia version, configuration hash, memory
estimate and `status` (`"running"` while the session computes, `"completed"`
once the record is final). Further entries are passed as keywords (`hardware`,
`deltas_computed`, `reference_checks`, `timings`, ...).
"""
function session_record(session::AbstractString, created, alg::AbstractSearch,
        settings::Settings, git::AbstractString, identity::AbstractDict,
        memory_bytes::Integer; status::AbstractString, entries...)
    record = Dict{String, Any}("id" => session, "created" => created,
        "kernel" => kernel_name(alg),
        "backend" =>
            alg isa DeviceSearch ? backend_name(alg.backend) : String(settings.backend),
        "threads" => Threads.nthreads(), "chunk_size" => settings.chunk_size,
        "package_version" => string(pkgversion(WaitingTimes)), "git" => git,
        "producer" => identity, "julia" => string(VERSION),
        "config_hash" => content_hash(settings.raw),
        "memory_estimate_bytes" => memory_bytes, "status" => String(status))
    for (key, value) in entries
        record[String(key)] = value
    end
    return record
end

"""
$(TYPEDSIGNATURES)

Generate (or extend) the collection of waiting-time distributions described
by `settings`: prepare the series, compute every configured threshold not yet
present, write partitions, run reference checks, and record the session.
`kernel` replaces the configured search kernel (`[algorithm].search`).

The session is resumable: `index.toml`, `summary.csv` and `catalog.csv` are
rewritten after every chunk of thresholds, so an interrupted run leaves a
collection whose index lists every partition written, and the next run
computes only the rest. The session record is written with `status =
"running"` before the first threshold and rewritten with `status =
"completed"` at the end. With `[algorithm].reference_checks > 0` the kernel is
compared with the reference kernel on the largest pending threshold within
`[limits].max_reference_work` before any partition is written; a disagreement
raises there.
"""
function generate(settings::Settings; kernel::AbstractSearch = make_kernel(settings))
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
    created = now(UTC)
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
        isfile(meta_path) || write_toml(meta_path, meta)   # loadable from the first session on
        isfile(joinpath(dir, "gaps.csv")) || @timeit timer "series files" begin
            write_series_files(dir, s, settings.output_format; rows = ids.rows,
                time_original = ids.time_original,
                gaps_original = ids.time_axis === :index ? ids.gaps_original : nothing)
            write_toml(joinpath(dir, "series.toml"), series_summary(ids, s))
        end

        alg = kernel
        bytes = estimate_memory_bytes(s, alg;
            store_waiting_times = settings.store_waiting_times)
        limit = settings.max_ram_gb * 2^30
        bytes <= limit || throw(ArgumentError(
            "estimated memory $(round(bytes / 2^30; digits = 2)) GiB exceeds [limits] max_ram_gb = $(settings.max_ram_gb)",
        ))
        thresholds = threshold_list(settings, s)
        entries = read_index(dir)
        existing = Dict(e["delta"] => e for e in entries)
        todo = eltype(thresholds)[]
        for δ in thresholds
            key = format_threshold(δ)
            if haskey(existing, key) && !settings.overwrite
                push!(skipped, key)
            else
                push!(todo, δ)
            end
        end
        reference = settings.reference_checks > 0 && !isempty(todo) ?
                    make_reference_kernel(settings) : nothing
        devices = DeviceSearch[k for k in (alg, reference) if k isa DeviceSearch]
        for k in devices
            host_backend(k.backend) && continue
            vram = length(s) * (2 * sizeof(eltype(s.values)) + 2 * sizeof(eltype(s.times)))
            vram <= settings.max_vram_gb * 2^30 || throw(ArgumentError(
                "estimated device memory $(round(vram / 2^30; digits = 2)) GiB exceeds [limits] max_vram_gb = $(settings.max_vram_gb)",
            ))
            @info "device backend" name=backend_name(k.backend) device_gib=round(vram/2^30; digits = 3)
        end
        @info "thresholds" total=length(thresholds) existing=length(existing) kernel=kernel_name(alg) memory_gib=round(
            bytes/2^30; digits = 3)
        ws = @timeit timer "workspace" workspace(alg, s)
        ws_ref = reference === nothing ? nothing :
                 @timeit timer "workspace" workspace(reference, s)
        # The Fenwick sweep serves every threshold of a batch in one pass; the
        # batch is as large as the memory bound leaves room for, counting the
        # result vector and the per-threshold transients of each threshold.
        Tt = eltype(s.times)
        transient = transient_bytes(s; store_waiting_times = settings.store_waiting_times)
        batch = alg isa FenwickSweep ?
                clamp(
            floor(Int, (limit - bytes) / (length(s) * sizeof(Tt) + transient)), 1,
            max(1, length(todo))) : 1
        τs = [Vector{Tt}(undef, length(s)) for _ in 1:min(batch, max(1, length(todo)))]
        session_path = joinpath(dir, "sessions", session * ".toml")
        write_toml(session_path,
            session_record(session, created, alg, settings, git, identity, bytes;
                status = "running", deltas_skipped = skipped))
        if reference !== nothing
            early = early_reference_check(timer, s, todo, alg, ws, reference, ws_ref,
                settings)
            early === nothing || push!(checks, early)
        end
        progress = run_progress(length(thresholds))
        foreach(_ -> next!(progress), skipped)
        last_checkpoint = time()
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
            # resume state: the index lists every partition written so far,
            # rewritten at most every [run].checkpoint_seconds
            if time() - last_checkpoint >= settings.checkpoint_seconds
                @timeit timer "write" write_index_files(dir, existing, id, ids.series_slug,
                    s.digits)
                last_checkpoint = time()
            end
        end
        finish!(progress)

        if reference !== nothing && !isempty(computed)
            early_key = isempty(checks) ? nothing : checks[1]["delta"]
            append!(checks,
                reference_check!(timer, s, thresholds, computed, alg, ws, reference,
                    ws_ref, settings; exclude = early_key))
        end

        entries = write_index_files(dir, existing, id, ids.series_slug, s.digits)

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
        record = session_record(session, created, alg, settings, git, identity, bytes;
            status = "completed", manifest_sha256 = manifest_sha, hardware = hardware,
            deltas_computed = computed, deltas_skipped = skipped,
            reference_checks = checks, timings = timings(timer))
        write_toml(session_path, record)
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
        for k in devices
            reclaim_device_memory!(k.backend)
        end
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

Compare the kernel `alg` (workspace `ws`) with the kernel `reference`
(workspace `ws_ref`) on the threshold `δ` of `s`, index by index. The scan
work of the comparison ([`scan_work`](@ref), in element comparisons, guarded
unless `reference` is a `NaiveSearch`) is computed from the result of `alg`;
above `max_work` the reference kernel is not run and the comparison is
skipped. Returns `(equal, n_differences, work, skipped, seconds)`: whether the
results agree, the number of differing indices, the work, whether the
comparison was skipped (then `equal = false` and `n_differences = 0`), and the
seconds the reference kernel took.
"""
function compare_with_reference(s::QuantizedSeries, δ::Threshold, alg::AbstractSearch,
        ws, reference::AbstractSearch, ws_ref; max_work::Real)
    τ = Vector{eltype(s.times)}(undef, length(s))
    waiting_times!(τ, s, δ, alg; workspace = ws)
    work = Float64(scan_work(τ, s; guarded = !(reference isa NaiveSearch)))
    work > max_work &&
        return (equal = false, n_differences = 0, work = work, skipped = true,
            seconds = 0.0)
    τ_reference = similar(τ)
    seconds = @elapsed waiting_times!(τ_reference, s, δ, reference; workspace = ws_ref)
    n_differences = count(i -> τ_reference[i] != τ[i], eachindex(τ))
    return (equal = n_differences == 0, n_differences = n_differences, work = work,
        skipped = false, seconds = seconds)
end

"""
$(TYPEDSIGNATURES)

Thresholds for reference comparisons among `thresholds`: the largest, always
included, followed by `n - 1` others drawn without replacement with `rng`
(none for `n <= 1`). Empty when `thresholds` is.
"""
function reference_thresholds(thresholds::AbstractVector, n::Integer, rng::AbstractRNG)
    isempty(thresholds) && return eltype(thresholds)[]
    sorted = sort(thresholds)
    chosen = [last(sorted)]
    append!(chosen, first(shuffle(rng, sorted[1:(end - 1)]), max(0, n - 1)))
    return chosen
end

"session record of one reference comparison `r` at threshold `key`"
function check_record(key::AbstractString, reference::AbstractSearch, r; early::Bool = false)
    record = Dict{String, Any}("delta" => key, "kernel" => kernel_name(reference),
        "skipped" => r.skipped, "work" => r.work)
    if !r.skipped
        record["equal"] = r.equal
        record["seconds"] = r.seconds
    end
    early && (record["early"] = true)
    return record
end

function reference_disagreement(key, alg::AbstractSearch, reference::AbstractSearch)
    error("reference disagreement at delta = $key between $(kernel_name(alg)) and $(kernel_name(reference))")
end

"""
$(TYPEDSIGNATURES)

Compare `alg` with the reference kernel on the largest threshold of `todo`
whose scan work lies within `[limits].max_reference_work`, before any
partition is written. Returns the check record (with `early = true`), or
`nothing` with a warning when no threshold is within the bound; a
disagreement raises.
"""
function early_reference_check(timer, s, todo, alg, ws, reference, ws_ref,
        settings::Settings)
    for δ in sort(todo; rev = true)
        r = @timeit timer "reference" compare_with_reference(s, δ, alg, ws, reference,
            ws_ref; max_work = settings.max_reference_work)
        r.skipped && continue
        key = format_threshold(δ)
        @info "reference check" delta=key kernel=kernel_name(reference) equal=r.equal seconds=round(
            r.seconds; digits = 3) early=true
        r.equal || reference_disagreement(key, alg, reference)
        return check_record(key, reference, r; early = true)
    end
    @warn "early reference check skipped: no pending threshold within [limits] max_reference_work"
    return nothing
end

"""
$(TYPEDSIGNATURES)

Recompute `settings.reference_checks` thresholds among those just computed with
the reference kernel (always including the largest, see
`reference_thresholds`) and compare exactly (`compare_with_reference`); the
threshold `exclude`, already compared
by the early check, is not repeated. A disagreement raises after being
recorded; a check whose scan work ([`scan_work`](@ref), in element
comparisons) exceeds `[limits].max_reference_work` is skipped with a warning.
"""
function reference_check!(timer, s, thresholds, computed, alg, ws, reference, ws_ref,
        settings::Settings; exclude = nothing)
    by_key = Dict(format_threshold(δ) => δ for δ in thresholds)
    keys_ = sort(computed; by = k -> parse_threshold(k, s.digits).d)
    chosen = reference_thresholds([by_key[k] for k in keys_], settings.reference_checks,
        MersenneTwister(settings.seed))
    checks = Dict{String, Any}[]
    for δ in chosen
        key = format_threshold(δ)
        key == exclude && continue
        r = @timeit timer "reference" compare_with_reference(s, δ, alg, ws, reference,
            ws_ref; max_work = settings.max_reference_work)
        push!(checks, check_record(key, reference, r))
        if r.skipped
            @warn "reference check skipped: work bound exceeds [limits] max_reference_work" delta=key work=r.work
            continue
        end
        @info "reference check" delta=key kernel=kernel_name(reference) equal=r.equal seconds=round(
            r.seconds; digits = 3)
        r.equal || reference_disagreement(key, alg, reference)
    end
    return checks
end

"""
$(TYPEDSIGNATURES)

Compare kernels with the reference kernel (`[algorithm].reference_kernel`) on
the series of `settings`, through `compare_with_reference` with the work
bound `[limits].max_reference_work`. `deltas` are the thresholds compared
(`Threshold`s, real values or decimal strings on the grid of the series); by
default the largest configured threshold and `reference_checks - 1` random
ones (`reference_thresholds`). `kernels` is a vector of `name => alg`
pairs compared in turn; by default the configured kernel alone. The reference
kernel runs once per threshold, every kernel being compared with that result.

Returns a report dictionary: `series`, `kernel` (the kernel names),
`reference_kernel`, `all_equal` (no disagreement on any compared threshold),
`results` (one dictionary per kernel and threshold: `kernel`, `delta`,
`equal`, `n_differences`, `work`, `skipped`, `seconds` of the reference
kernel) and `kernels` (one dictionary per kernel: `name`, `equal`, `n_checked`
thresholds compared, `n_differences` summed over them, `n_skipped` above the
work bound, `seconds` of the reference kernel summed). Disagreements are
reported, not thrown.
"""
function validate(settings::Settings; deltas = nothing, kernels = nothing)
    s, ids = prepare(settings)
    reference = make_reference_kernel(settings)
    named = if kernels === nothing
        configured = make_kernel(settings)
        Pair{String, AbstractSearch}[kernel_name(configured) => configured]
    else
        Pair{String, AbstractSearch}[String(first(p)) => last(p) for p in kernels]
    end
    results, summaries = compare_kernels(s, deltas, named, reference, settings)
    return Dict{String, Any}("series" => ids.series_id,
        "kernel" => join(first.(named), ", "),
        "reference_kernel" => kernel_name(reference),
        "all_equal" => all(k -> k["equal"], summaries),
        "results" => results, "kernels" => summaries)
end

"""
Comparison loop of [`validate`](@ref) on the series `s`: the thresholds are
placed on the grid of `s` (`deltas`, or the sampled set of `reference_thresholds`
when `nothing`), the reference kernel runs once per threshold within
`[limits].max_reference_work`, and every kernel of `named` is compared with
that result. Returns the per-threshold results and the per-kernel summaries.
"""
function compare_kernels(s::QuantizedSeries{Tv, Tt}, deltas, named, reference,
        settings::Settings) where {Tv, Tt}
    thresholds = deltas === nothing ?
                 reference_thresholds(threshold_list(settings, s),
        settings.reference_checks, MersenneTwister(settings.seed)) :
                 Threshold{Tv}[δ isa Threshold ? Threshold{Tv}(δ.d, δ.digits) :
                               WaitingTimes.threshold(δ, s) for δ in deltas]
    ws_ref = workspace(reference, s)
    wss = [workspace(alg, s) for (_, alg) in named]
    results = Dict{String, Any}[]
    summaries = [Dict{String, Any}("name" => name, "equal" => true, "n_checked" => 0,
                     "n_differences" => 0, "n_skipped" => 0, "seconds" => 0.0)
                 for (name, _) in named]
    τ = Vector{Tt}(undef, length(s))
    τ_reference = similar(τ)
    guarded = !(reference isa NaiveSearch)
    for δ in thresholds
        key = format_threshold(δ)
        waiting_times!(τ, s, δ, last(named[1]); workspace = wss[1])
        work = Float64(scan_work(τ, s; guarded = guarded))
        skipped = work > settings.max_reference_work
        seconds = skipped ? 0.0 :
                  @elapsed waiting_times!(τ_reference, s, δ, reference; workspace = ws_ref)
        for (k, (name, alg)) in enumerate(named)
            k == 1 || waiting_times!(τ, s, δ, alg; workspace = wss[k])
            n_differences = skipped ? 0 : count(i -> τ_reference[i] != τ[i], eachindex(τ))
            equal = !skipped && n_differences == 0
            push!(results,
                Dict{String, Any}("kernel" => name, "delta" => key, "equal" => equal,
                    "n_differences" => n_differences, "work" => work,
                    "skipped" => skipped, "seconds" => seconds))
            summary = summaries[k]
            if skipped
                summary["n_skipped"] += 1
            else
                summary["n_checked"] += 1
                summary["n_differences"] += n_differences
                summary["seconds"] += seconds
                summary["equal"] &= equal
            end
        end
    end
    return results, summaries
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
