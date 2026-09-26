# Worked consumer: a DeepSpaceTelemetry.jl run directory as the source of a
# series with gaps, and a collection of waiting-time distributions from it.
#
#   julia --threads=3 examples/telemetry_run.jl [RUN_DIRECTORY] [--out DIR]
#
# Without a run directory the shipped `drop_policy` scenario is run first
# (three mission days at the configured acceleration, about two minutes; a
# lossy channel whose rejected transfers are dropped for good, so about one
# fifth of the batches never reach the ground), with its data root redirected
# to the output directory so that nothing is written into the installed
# package. The run-directory contract of
# DeepSpaceTelemetry is read as its documentation states it: delivered
# batches under `ground/<BATCH>/`, each with `metadata.json` (content epoch)
# and `seg_<id>.csv` (one `Amplitude` column), sample `k` of a batch at
# `content_epoch + (k - 1) / sample_rate` with `sample_rate` from the run's
# `config_snapshot.toml`. Batches that never reached the ground are the gaps
# of the series. The delivered payload of the synthetic scenario is a flag
# series, so a second series is built by masking a random walk with the same
# availability, which shows the gap classification on a signal with
# structure.
include(joinpath(@__DIR__, "activate.jl"))

using CSV: CSV
using DataFrames: DataFrame
using Dates: DateTime, Millisecond
using DeepSpaceTelemetry: DeepSpaceTelemetry
using JSON3: JSON3
using Printf: @printf
using StableRNGs: StableRNG
using TOML: TOML
using WaitingTimes
using WaitingTimes.Preprocessing: RawSeries, quantized_series
using WaitingTimes.Synthetic: random_walk

arg(flag) = (i = findfirst(==(flag), ARGS); i === nothing ? nothing : ARGS[i + 1])
out_dir = something(arg("--out"), joinpath(@__DIR__, "output"))
run_dir = let positional = filter(a -> !startswith(a, "--") && a != something(arg("--out"), ""), ARGS)
    isempty(positional) ? nothing : abspath(first(positional))
end

# --- a run directory ----------------------------------------------------------
if run_dir === nothing
    DeepSpaceTelemetry.TelemetryCore.DATA_ROOT[] = joinpath(out_dir, "dst")
    mkpath(DeepSpaceTelemetry.TelemetryCore.runs_root())
    scenario = joinpath(pkgdir(DeepSpaceTelemetry), "scenarios", "drop_policy.toml")
    run_id = "wt_drop_" * string(round(Int, time()))
    DeepSpaceTelemetry.Supervisor.run_mission(
        DeepSpaceTelemetry.TelemetryCore.load_config(scenario); run_id = run_id)
    global run_dir = DeepSpaceTelemetry.TelemetryCore.run_directory(run_id)
end
println("run directory ", run_dir)

# --- the file contract, read directly -------------------------------------------
snapshot_cfg = TOML.parsefile(joinpath(run_dir, "config_snapshot.toml"))
sample_rate = Float64(snapshot_cfg["physics"]["sample_rate"])
period_ms = round(Int, 1000 / sample_rate)
period_ms * sample_rate == 1000 ||
    error("sample rate $sample_rate Hz is not a whole number of milliseconds")

"delivered batches as (content epoch, samples) pairs, in epoch order"
function delivered_batches(run_dir)
    batches = Tuple{DateTime, Vector{Float64}}[]
    ground = joinpath(run_dir, "ground")
    for name in readdir(ground)
        dir = joinpath(ground, name)
        meta_path = joinpath(dir, "metadata.json")
        isfile(meta_path) || continue
        meta = JSON3.read(read(meta_path, String), Dict{String, Any})
        haskey(meta, "content_epoch") || continue
        epoch = DateTime(String(meta["content_epoch"]))
        segments = sort(filter(f -> occursin(r"^seg_\d+\.csv$", f), readdir(dir));
            by = f -> parse(Int, match(r"\d+", f).match))
        isempty(segments) && continue                 # payload pruned by retention
        samples = reduce(vcat, [Vector{Float64}(CSV.read(joinpath(dir, f), DataFrame).Amplitude)
                                for f in segments])
        push!(batches, (epoch, samples))
    end
    sort!(batches; by = first)
    return batches
end

batches = delivered_batches(run_dir)
isempty(batches) && error("no delivered batch with a payload under $run_dir")
origin = first(batches)[1]
times = Int64[]
values = Union{Missing, Float64}[]
for (epoch, samples) in batches
    start_ms = Millisecond(epoch - origin).value
    for (k, v) in enumerate(samples)
        push!(times, start_ms + (k - 1) * period_ms)
        push!(values, v)
    end
end
println(length(batches), " delivered batches, ", length(values), " samples at ", sample_rate,
    " Hz, ", period_ms, " ms per sample")

# --- a series with the mission's gaps --------------------------------------------
# The delivered flag series as recorded, and a random walk masked with the same
# availability: both carry the same gap structure, the second has dynamics.
flag = quantized_series(RawSeries(values, times, :millisecond, nothing,
        PreparationRecord(run_dir)), 0; detect = :threshold, threshold = period_ms)
println("flag series: ", flag)
rng = StableRNG(7)
walk = round.(random_walk(rng, length(values)); digits = 2)
signal = quantized_series(RawSeries(Vector{Union{Missing, Float64}}(walk), times,
        :millisecond, nothing, PreparationRecord("random walk on the mission's availability")),
    2; detect = :threshold, threshold = period_ms)
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

# --- a collection on disk ------------------------------------------------------------
mktempdir() do dir
    csv = joinpath(dir, "masked_walk.csv")
    CSV.write(csv, DataFrame(time_ms = signal.times, value = walk))
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
        [gaps]
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
    println(summary_table(c)[:, [:delta, :n_exact, :n_gap_crossing, :n_right_censored, :tau_mean]])
end
