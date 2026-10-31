# Worked consumer and collection contract for DeepSpaceTelemetry.jl: a run
# directory as the source of a series with gaps, and collections of
# waiting-time distributions, on the elapsed and on the index axis, that name
# the run they came from.
#
#   julia examples/telemetry_run.jl [RUN_DIRECTORY] [--out DIR]
#
# Without a run directory the shipped `drop_policy` scenario runs first, on
# the tick clock: three mission days, deterministic, about a minute with its
# post-processing, the figure stages skipped. Its lossy channel drops rejected transfers for good, so
# about one sixth of the batches are lost and as many are still undelivered
# at mission end. The run is placed under the output directory
# (`run_mission(cfg; data_root)`), so nothing is written into the installed
# package. A given run directory must be a finished run of DeepSpaceTelemetry
# 2.6 or later, the oldest producer the adapter opens by default.
#
# The run directory is read through the producer's adapter
# (`DeepSpaceTelemetry.RunAdapter`, public since 2.6.2; since 2.9.0 it lives
# in the reader subpackage `DeepSpaceTelemetryReader`, re-exported under the
# same qualified names; stable within 3.x, where the producer is maintained
# rather than extended; see the producers page of the documentation). Sample
# `k` of a batch lies at payload row
# `payload_row + k - 1`, and time `(r - 1) / sample_rate` from the origin is
# payload row `r` (`row_time`). `masks/gaps.csv`, the settled table of every
# hole of the delivered record with its cause (lost, pruned, undelivered,
# generation gaps), is read with `TelemetryCore.read_table`. Its holes are the
# declared gaps of the series, of kind "gap", and cross-check the gaps
# detected from the sample spacing, which cannot tell the causes apart and
# cannot see a hole before the first or after the last delivered sample.
#
# `descriptor.toml` is the run's identity (run, producer version and code
# identity, configuration hash, seed, product checksums);
# `[input].source_descriptor` carries it into the collection. The
# authoritative key of the producer's code is `git_tree_sha1` with
# `git_dirty = false`; `git_commit` is filled when the producer was pinned by
# a full commit hash, as here (DeepSpaceTelemetry 2.6.1 and later; in an older
# run the keys are missing, which means unknown).
#
# The delivered payload of the synthetic scenario is a flag series, so a
# second series is built by masking a random walk with the same availability;
# it shows the gap classification on a signal with structure. The collections
# of the masked walk assert the collection contract (see the last section).
include(joinpath(@__DIR__, "activate.jl"))

using CSV: CSV
using DataFrames: DataFrame, nrow
using DeepSpaceTelemetry: DeepSpaceTelemetry
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
TC = DeepSpaceTelemetry.TelemetryCore
RA = DeepSpaceTelemetry.RunAdapter
if run_dir === nothing
    scenario = joinpath(pkgdir(DeepSpaceTelemetry), "scenarios", "drop_policy.toml")
    run_id = "wt_drop_" * string(round(Int, time()))
    started = time()
    global run_dir = DeepSpaceTelemetry.Supervisor.run_mission(
        TC.tick_configuration(TC.load_config(scenario));
        run_id, figures = false, data_root = joinpath(out_dir, "dst"))
    @printf("tick-clock mission and post-processing: %.0f s\n", time() - started)
end
println("run directory ", run_dir)
descriptor_path = joinpath(run_dir, "descriptor.toml")
gaps_path = joinpath(run_dir, "masks", "gaps.csv")
isfile(descriptor_path) && isfile(gaps_path) ||
    error("$run_dir has no descriptor.toml or masks/gaps.csv; a finished run of DeepSpaceTelemetry 2.6 or later is required")

# --- the run, through the producer's adapter ----------------------------------------
run = RA.open_run(run_dir)                 # the producer's version and the lifecycle sentinel checked
RA.run_state(run) === :complete ||
    error("$run_dir is not a finished run (state $(RA.run_state(run)))")
geometry = RA.run_geometry(run)
sample_rate = geometry.sample_rate
period_ms = round(Int, 1000 / sample_rate)
period_ms * sample_rate == 1000 ||
    error("sample rate $sample_rate Hz is not a whole number of milliseconds")
println(
    "producer ", geometry.package_version, ", clock ", geometry.mode, ", payload origin ",
    geometry.payload_origin, ", columns ", join(geometry.columns, ", "))

"delivered batches as (start time in ms from the payload origin, samples), in time order"
function delivered_batches(run, geometry, period_ms)
    batches = Tuple{Int64, Vector{Float64}}[]
    for b in RA.list_batches(run)
        b.state === :ground || continue           # lost: never delivered; pruned: payload removed by retention
        ismissing(b.content_epoch) ||
            RA.row_time(geometry, first(b.rows)) == b.content_epoch ||
            error("$(b.name): content epoch and payload row disagree")
        samples = Float64.(RA.read_batch(run, b.name))
        length(samples) == length(b.rows) ||
            error("$(b.name): $(length(samples)) samples for $(length(b.rows)) payload rows")
        push!(batches, ((first(b.rows) - 1) * period_ms, samples))
    end
    sort!(batches; by = first)
    return batches
end

batches = delivered_batches(run, geometry, period_ms)
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
holes = TC.read_table(gaps_path)           # the settled gap table, column types as the contract states them
causes = String.(holes.Cause)
println("holes of the delivered record (masks/gaps.csv):")
for cause in sort(unique(causes))
    sel = causes .== cause
    @printf("  %-13s %4d holes %9d rows\n", cause, count(sel),
        sum(holes.RowLast[sel] .- holes.RowFirst[sel] .+ 1))
end
feed = RA.declared_holes(run)              # holes.csv, each hole with the instant it was declared
if !isempty(feed)
    settled = Set((String(h.cause), first(h.rows), last(h.rows)) for h in feed) ==
              Set(zip(causes, Int.(holes.RowFirst), Int.(holes.RowLast)))
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
declared = [(start = (a - 1) * period_ms, stop = b * period_ms, kind = "gap",
                source = "masks/gaps.csv")
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

# --- collections that name their source ----------------------------------------------
# One collection on the elapsed axis (milliseconds from the payload origin) and
# one on the index axis. The series file holds every payload row from the first
# to the last delivered sample, the rows of the holes as missing values, so the
# index axis is the payload row (counted from the first delivered row) and the
# declared holes stay gaps, of kind "gap", on both. The collection contract
# (provenance schema 3, source summary, gap kinds, record structure, per-class
# partitions) is asserted, so that a change of the producer that breaks it
# fails here.
"assert one clause of the collection contract, naming it when it fails"
function contract(ok::Bool, clause::AbstractString)
    ok || error("collection contract broken: $clause")
end

mktempdir() do dir
    row(t) = t ÷ period_ms + 1
    rows = row(first(times)):row(last(times))
    full = Vector{Union{Missing, Float64}}(missing, length(rows))
    full[row.(times) .- first(rows) .+ 1] .= walk
    csv = joinpath(dir, "masked_walk.csv")
    CSV.write(csv, DataFrame(time_ms = (rows .- 1) .* period_ms, value = full))
    holes_toml = joinpath(dir, "holes.toml")
    open(
        io -> TOML.print(io,
            Dict("kind" => "gap", "source" => "masks/gaps.csv",
                "intervals" => [[g.start, g.stop] for g in declared])),
        holes_toml,
        "w")
    collections = Dict{String, Any}()
    for axis in ("elapsed", "index")
        config = joinpath(dir, "masked_walk_$(axis).toml")
        open(config, "w") do io
            TOML.print(io,
                Dict(
                    "input" =>
                        Dict("path" => csv, "format" => "csv", "value_column" => "value",
                            "time_column" => "time_ms", "time_unit" => "millisecond",
                            "epoch_unit" => "millisecond", "time_axis" => axis,
                            "source_descriptor" => descriptor_path),
                    "gaps" => Dict("declared" => holes_toml, "detect" => "threshold",
                        "threshold" => period_ms),
                    "quantization" => Dict("digits" => 2),
                    "thresholds" =>
                        Dict("mode" => "explicit", "values" => [0.5, 1.0, 2.0, 5.0]),
                    "output" =>
                        Dict("root" => joinpath(out_dir, "collections"), "format" => "csv")))
        end
        collections[axis] = load_collection(run_pipeline(config).dir)
    end
    ce, ci = collections["elapsed"], collections["index"]
    show(stdout, MIME("text/plain"), ce)
    println()
    println(summary_table(ce)[:, [
        :delta, :n_exact, :n_gap_crossing, :n_right_censored, :tau_mean]])

    descriptor = TOML.parsefile(descriptor_path)
    for c in (ce, ci)
        contract(c.metadata["schema"] == "waitingtimes-provenance/3", "schema 3")
        contract(read(joinpath(c.dir, "source.toml")) == read(descriptor_path),
            "source.toml is the run's descriptor.toml")
        summary = WaitingTimes.source_summary(c)
        contract(summary.producer == "DeepSpaceTelemetry" && summary.compat_satisfied,
            "source summary names an admitted DeepSpaceTelemetry")
        contract(
            summary.git_tree_sha1 == get(descriptor, "git_tree_sha1", "") &&
                summary.identity == haskey(descriptor, "git_tree_sha1"),
            "the producer's code identity is carried")
        contract(
            all(haskey(c.metadata["producer"], k)
            for k in ("name", "version", "git_tree_sha1", "git_dirty", "git_commit")),
            "[producer] identity")
        contract(isfile(joinpath(c.dir, c.metadata["environment"]["manifest_file"])),
            "manifest snapshot")
        gaps = CSV.read(joinpath(c.dir, "gaps.csv"), DataFrame)
        contract(
            nrow(gaps) == length(merged) && all(==("gap"), gaps.kind) &&
                all(==("masks/gaps.csv"), gaps.source),
            "the holes are the gaps, of kind gap")
        contract(
            length(WaitingTimes.segment_lengths(c)) == nrow(gaps) + 1 &&
                sum(WaitingTimes.segment_lengths(c)) == c.n_observations,
            "segments")
        contract(WaitingTimes.record_length(c) == length(rows), "record length in payload rows")
        for δ in (0.5, 5.0)
            d = distribution(c, δ)
            cc = WaitingTimes.class_counts(c, δ)
            ch = WaitingTimes.censoring_histogram(c, δ)
            contract(cc.exact .+ cc.gap_crossing == WaitingTimes.counts(d), "per-class counts")
            contract(sum(ch.count) == d.n_right_censored, "censoring histogram")
        end
    end
    contract(ci.time_axis === :index && isfile(joinpath(ci.dir, "gaps_original.csv")),
        "index axis with the gaps of the original clock")
    contract(distribution(ce, 5.0).n_gap_crossing == distribution(ci, 5.0).n_gap_crossing,
        "the holes classify the waits alike on both axes")

    summary = WaitingTimes.source_summary(ce)
    println("source: run ", descriptor["run_id"], ", ", summary.producer, " ",
        summary.producer_version, ", configuration ", first(descriptor["config_sha256"], 16),
        ", seed ", descriptor["rng_seed"])
    println("producer code: tree ",
        summary.identity ? summary.git_tree_sha1 : "not recorded (run before 2.6.1)",
        ", commit ", isempty(summary.git_commit) ? "not recorded" : summary.git_commit,
        summary.git_dirty ? ", modified after installation or uncommitted changes" : "")
    println("collection contract holds on both axes")
end
