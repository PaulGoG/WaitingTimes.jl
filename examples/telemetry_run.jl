# Worked consumer: a DeepSpaceTelemetry.jl run directory as the source of a
# series with gaps, and a collection of waiting-time distributions that names
# the run it came from.
#
#   julia --threads=3 examples/telemetry_run.jl [RUN_DIRECTORY] [--out DIR]
#
# Without a run directory the shipped `drop_policy` scenario is run first on
# the tick clock (three mission days, deterministic, about a minute with its
# post-processing; a lossy channel whose rejected transfers are dropped for
# good, so about one sixth of the batches are lost and as many are still
# undelivered at mission end), with its data root redirected to the output
# directory so that nothing is written into the installed package. A given
# run directory must be a finished run of DeepSpaceTelemetry 2.5 or later.
#
# The run-directory contract is read as its documentation states it:
# delivered batches under `ground/<BATCH>/`, each with `metadata.json`
# (content epoch, payload row) and `seg_<id>.csv` (one `Amplitude` column),
# sample `k` of a batch at `content_epoch + (k - 1) / sample_rate`, with the
# sample rate and the payload origin from `config_snapshot.toml`; times are
# counted from the payload origin, so time `(r - 1) / sample_rate` is payload
# row `r`. `masks/gaps.csv` declares every hole of the delivered record with
# its cause (lost, pruned, undelivered, generation gaps): the holes are the
# declared gaps of the series and a cross-check of the gaps detected from the
# sample spacing, which cannot tell the causes apart and cannot see a hole
# before the first or after the last delivered sample. `descriptor.toml` is
# the run's identity (run, producer version and code identity, configuration
# hash, seed, product checksums); `[input].source_descriptor` carries it into
# the collection. The authoritative key of the producer's code is
# `git_tree_sha1` with `git_dirty = false`; `git_commit` is filled when the
# producer was pinned by a full commit hash, as here (DeepSpaceTelemetry
# 2.6.1 and later; in an older run the keys are missing, which means
# unknown). The delivered payload of the synthetic scenario is a flag
# series, so a second series is built by masking a random walk with the same
# availability, which shows the gap classification on a signal with
# structure.
include(joinpath(@__DIR__, "activate.jl"))

using CSV: CSV
using DataFrames: DataFrame, nrow
using Dates: DateTime, Millisecond
using DeepSpaceTelemetry: DeepSpaceTelemetry
using JSON: JSON
using Printf: @printf
using StableRNGs: StableRNG
using TOML: TOML
using WaitingTimes
using WaitingTimes.Preprocessing: RawSeries, quantized_series
using WaitingTimes.Synthetic: random_walk

arg(flag) = (i = findfirst(==(flag), ARGS); i === nothing ? nothing : ARGS[i + 1])
out_dir = abspath(something(arg("--out"), joinpath(@__DIR__, "output")))
run_dir = let positional = filter(
        a -> !startswith(a, "--") &&
             a != something(arg("--out"), ""), ARGS)
    isempty(positional) ? nothing : abspath(first(positional))
end

# --- a run directory ----------------------------------------------------------
if run_dir === nothing
    TC = DeepSpaceTelemetry.TelemetryCore
    TC.DATA_ROOT[] = joinpath(out_dir, "dst")
    mkpath(TC.runs_root())
    scenario = joinpath(pkgdir(DeepSpaceTelemetry), "scenarios", "drop_policy.toml")
    run_id = "wt_drop_" * string(round(Int, time()))
    seconds = @elapsed DeepSpaceTelemetry.Supervisor.run_mission(
        TC.tick_configuration(TC.load_config(scenario)); run_id = run_id)
    global run_dir = TC.run_directory(run_id)
    @printf("tick-clock mission and post-processing: %.0f s\n", seconds)
end
println("run directory ", run_dir)
descriptor_path = joinpath(run_dir, "descriptor.toml")
gaps_path = joinpath(run_dir, "masks", "gaps.csv")
isfile(descriptor_path) && isfile(gaps_path) ||
    error("$run_dir has no descriptor.toml or masks/gaps.csv; a finished run of DeepSpaceTelemetry 2.5 or later is required")

# --- the file contract, read directly -------------------------------------------
snapshot_cfg = TOML.parsefile(joinpath(run_dir, "config_snapshot.toml"))
sample_rate = Float64(snapshot_cfg["physics"]["sample_rate"])
period_ms = round(Int, 1000 / sample_rate)
period_ms * sample_rate == 1000 ||
    error("sample rate $sample_rate Hz is not a whole number of milliseconds")
origin = DateTime(snapshot_cfg["provenance"]["payload_origin"])

"delivered batches as (start time in ms from the payload origin, samples), in time order"
function delivered_batches(run_dir, origin, period_ms)
    batches = Tuple{Int64, Vector{Float64}}[]
    ground = joinpath(run_dir, "ground")
    for name in readdir(ground)
        dir = joinpath(ground, name)
        meta_path = joinpath(dir, "metadata.json")
        isfile(meta_path) || continue
        meta = JSON.parsefile(meta_path)
        start_ms = Millisecond(DateTime(String(meta["content_epoch"])) - origin).value
        start_ms == (meta["payload_row"] - 1) * period_ms ||
            error("$name: content epoch and payload row disagree")
        segments = sort(filter(f -> occursin(r"^seg_\d+\.csv$", f), readdir(dir));
            by = f -> parse(Int, match(r"\d+", f).match))
        isempty(segments) && continue                 # payload pruned by retention
        samples = reduce(vcat,
            [Vector{Float64}(CSV.read(joinpath(dir, f), DataFrame).Amplitude)
             for f in segments])
        push!(batches, (start_ms, samples))
    end
    sort!(batches; by = first)
    return batches
end

batches = delivered_batches(run_dir, origin, period_ms)
isempty(batches) && error("no delivered batch with a payload under $run_dir")
times = Int64[]
values = Union{Missing, Float64}[]
for (start_ms, samples) in batches
    for (k, v) in enumerate(samples)
        push!(times, start_ms + (k - 1) * period_ms)
        push!(values, v)
    end
end
println(
    length(batches), " delivered batches, ", length(values), " samples at ", sample_rate,
    " Hz, ", period_ms, " ms per sample")

# --- the declared holes ----------------------------------------------------------
# Rows are payload rows (inclusive), so a hole covers [(RowFirst - 1) P, RowLast P)
# in milliseconds from the payload origin, with P the sample period.
instants = Dict(:ContentStart => String, :ContentEnd => String)
holes = CSV.read(gaps_path, DataFrame; types = instants)
causes = String.(holes.Cause)
println("holes of the delivered record (masks/gaps.csv):")
for cause in sort(unique(causes))
    sel = causes .== cause
    @printf("  %-13s %4d holes %9d rows\n", cause, count(sel),
        sum(holes.RowLast[sel] .- holes.RowFirst[sel] .+ 1))
end
feed_path = joinpath(run_dir, "holes.csv")
if isfile(feed_path)
    feed = CSV.read(feed_path, DataFrame; types = merge(instants, Dict(:DeclaredAt =>
        String)))
    settled = Set(zip(String.(feed.Cause), feed.RowFirst, feed.RowLast)) ==
              Set(zip(causes, holes.RowFirst, holes.RowLast))
    println("holes.csv settled to the same ", nrow(holes), " holes: ", settled)
end

# Gaps of a series lie inside its record: the holes before the first and after
# the last delivered sample are reported, not declared. The spacing of the
# samples finds the holes inside, adjacent holes merged, without their causes.
first_row, last_row = times[1] ÷ period_ms + 1, times[end] ÷ period_ms + 1
inside = (holes.RowFirst .> first_row) .& (holes.RowLast .< last_row)
outside = causes[.!inside]
println(length(outside), " holes outside the delivered span: ",
    join(["$(count(==(c), outside)) $c" for c in sort(unique(outside))], ", "))
declared = [((a - 1) * period_ms, b * period_ms)
            for (a, b) in zip(holes.RowFirst[inside], holes.RowLast[inside])]
merged = Tuple{Int, Int}[]
for (a, b) in sort(collect(zip(holes.RowFirst[inside], holes.RowLast[inside])))
    if !isempty(merged) && a == merged[end][2] + 1
        merged[end] = (merged[end][1], b)
    else
        push!(merged, (a, b))
    end
end
spacing = quantized_series(
    RawSeries(values, times, :millisecond, nothing, PreparationRecord(run_dir)),
    0; detect = :threshold, threshold = period_ms)
spacing_rows = [((a - 1) ÷ period_ms + 2, b ÷ period_ms) for (a, b) in spacing.gaps]
println(length(spacing_rows), " gaps from the sample spacing, equal to the ",
    count(inside), " declared holes inside the span with adjacent holes merged: ",
    spacing_rows == merged)

# --- a series with the mission's gaps --------------------------------------------
# The delivered flag series as recorded, and a random walk masked with the same
# availability: both carry the declared holes, the second has dynamics.
flag = quantized_series(
    RawSeries(values, times, :millisecond, nothing, PreparationRecord(run_dir)),
    0; detect = :threshold, threshold = period_ms, declared = declared)
println("flag series: ", flag)
rng = StableRNG(7)
walk = round.(random_walk(rng, length(values)); digits = 2)
signal = quantized_series(
    RawSeries(Vector{Union{Missing, Float64}}(walk), times,
        :millisecond, nothing, PreparationRecord("random walk on the mission's availability")),
    2; detect = :threshold, threshold = period_ms, declared = declared)
println("masked walk:  ", signal)
table = gap_table(signal)
println("longest gaps [ms]: ", [(g.start, g.stop, g.length) for g in first(table, 3)])

for δ in (0.5, 5.0)
    thr = threshold(δ, signal)
    τ = waiting_times(signal, thr)
    d = empirical_distribution(τ, thr, signal)
    @printf("  δ = %-4s exact %7d  gap-crossing %6d  right-censored %6d  mean wait %9.1f ms\n",
        format_threshold(thr), d.n_exact, d.n_gap_crossing, d.n_right_censored,
        WaitingTimes.mean_waiting_time(d))
end

# --- a collection on disk that names its source ----------------------------------------
mktempdir() do dir
    csv = joinpath(dir, "masked_walk.csv")
    CSV.write(csv, DataFrame(time_ms = signal.times, value = walk))
    holes_toml = joinpath(dir, "holes.toml")
    open(io -> TOML.print(io, Dict("intervals" => [[a, b] for (a, b) in declared])),
        holes_toml, "w")
    config = joinpath(dir, "masked_walk.toml")
    open(config, "w") do io
        print(io, """
        [input]
        path = "$(csv)"
        format = "csv"
        value_column = "value"
        time_column = "time_ms"
        time_unit = "millisecond"
        epoch_unit = "millisecond"
        source_descriptor = "$(descriptor_path)"
        [gaps]
        declared = "$(holes_toml)"
        detect = "threshold"
        threshold = $(period_ms)
        [quantization]
        digits = 2
        [thresholds]
        mode = "explicit"
        values = [0.5, 1.0, 2.0, 5.0]
        [output]
        root = "$(joinpath(out_dir, "collections"))"
        format = "csv"
        """)
    end
    handle = run_pipeline(config)
    c = load_collection(handle.dir)
    show(stdout, MIME("text/plain"), c)
    println()
    println(summary_table(c)[:, [
        :delta, :n_exact, :n_gap_crossing, :n_right_censored, :tau_mean]])
    source = source_descriptor(c)
    read(joinpath(c.dir, "source.toml")) == read(descriptor_path) ||
        error("source.toml of $(c.id) differs from the run's descriptor.toml")
    println("source: run ", source["run_id"], ", DeepSpaceTelemetry ",
        source["package_version"], ", configuration ", first(source["config_sha256"], 16),
        ", seed ", source["rng_seed"])
    tree = get(source, "git_tree_sha1", "")
    commit = get(source, "git_commit", "")
    origin_of_identity = get(
        Dict("work_tree" => "git work tree",
            "manifest" => "manifest entry", "directory" => "directory content"),
        get(source, "identity_source", ""), "")
    println(
        "producer code: tree ", isempty(tree) ? "not recorded (run before 2.6.1)" : tree,
        ", commit ", isempty(commit) ? "not recorded" : commit,
        isempty(origin_of_identity) ? "" : " (from the $(origin_of_identity))",
        get(source, "git_dirty", false) === true ?
        ", modified after installation or uncommitted changes" : "")
end
