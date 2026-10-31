# Gap kinds, record structure, time axes, per-class partitions, the series
# round trip and the summaries added with provenance schema 3.

using WaitingTimes: censoring_histogram, describe, observed_mask, record_length,
                    sampling_step, segment_lengths, segment_table, with_step
using WaitingTimes.Preprocessing: RawSeries, index_series, quantized_series,
                                  read_gap_intervals,
                                  round_values
using CSV: CSV
using DataFrames: DataFrame
using TOML: TOML

"collection configuration in `dir` for a CSV with columns `t` (seconds) and `x`"
function axis_config(
        dir, csv, axis; declared = "", mode = "elapsed", search = "segment_tree",
        root = joinpath(dir, "collections"))
    cfg = Dict{String, Any}(
        "input" =>
            Dict{String, Any}("path" => csv, "format" => "csv", "value_column" => "x",
                "time_column" => "t", "time_unit" => "second", "epoch_unit" => "second",
                "time_axis" => axis),
        "gaps" => Dict{String, Any}("detect" => "cadence", "cadence" => 1, "mode" => mode,
            "declared" => declared),
        "quantization" => Dict{String, Any}("digits" => 0),
        "thresholds" =>
            Dict{String, Any}("mode" => "explicit", "values" => [0.0, 1.0, 2.0]),
        "algorithm" => Dict{String, Any}("search" => search),
        "output" => Dict{String, Any}("root" => root, "format" => "csv"))
    path = joinpath(dir, "$(axis)_$(mode)_$(search).toml")
    open(io -> TOML.print(io, cfg), path, "w")
    return path
end

@testset "Gap kinds and merging" begin
    s = QuantizedSeries([1.0, missing, missing, 2.0, 3.0], 0)
    @test s.gaps == [(2, 4)] && s.gap_kinds == ["detected"] && s.gap_sources == [""]
    h = declare_gaps(s, [(2, 4)]; kind = "gap", source = "masks/gaps.csv")
    @test h.gaps == [(2, 4)] && h.gap_kinds == ["gap"] &&
          h.gap_sources == ["masks/gaps.csv"]
    @test length(s.record.steps) == 1 && h.record.steps[end].op === :declare_gaps

    # a detected gap absorbs the declared hole it overlaps (sample period 250)
    t = [0, 250, 1000, 1250]
    d = QuantizedSeries([1.0, 2.0, 3.0, 4.0], 0; times = t, cadence = 250)
    @test d.gaps == [(251, 1000)]
    g = declare_gaps(d, [(500, 1000)]; kind = "gap", source = "masks/gaps.csv")
    @test g.gaps == [(251, 1000)] && g.gap_kinds == ["gap"]

    base = QuantizedSeries(Int32[1, 2], [1, 10], 0)
    touching = declare_gaps(base,
        [(start = 2, stop = 5, kind = "session", source = "calendar"),
            (start = 5, stop = 10, kind = "hole", source = "holes.csv")])
    @test touching.gaps == [(2, 5), (5, 10)] && touching.gap_kinds == ["session", "hole"]
    overlapping = declare_gaps(base,
        [(start = 2, stop = 6, kind = "hole", source = "a"),
            (start = 5, stop = 10, kind = "session", source = "b")])
    @test overlapping.gaps == [(2, 10)] && overlapping.gap_kinds == ["session+hole"] &&
          overlapping.gap_sources == ["a;b"]
    same = declare_gaps(base, [(2, 5), (5, 10)]; kind = "hole")
    @test same.gaps == [(2, 10)] && same.gap_kinds == ["hole"]
    @test_throws ArgumentError declare_gaps(base, [(2, 5)]; kind = "detected")
    @test_throws ArgumentError declare_gaps(base, [(2, 5)]; kind = "outage")
    @test_throws ArgumentError declare_gaps(base, [(0, 5)])
    @test_throws DimensionMismatch QuantizedSeries(
        Int32[1, 2], [1, 10], 0; gaps = [(2, 5)],
        gap_kinds = String[])
    @test gap_table(touching)[1] ==
          (start = 5, stop = 10, length = 5, kind = "hole", source = "holes.csv")

    mktempdir() do dir
        path = joinpath(dir, "holes.toml")
        write(path, """
            kind = "gap"
            source = "masks/gaps.csv"
            intervals = [[2, 5]]
            [[gaps]]
            start = 6
            stop = 8
            kind = "session"
            """)
        entries = read_gap_intervals(path)
        @test entries == [(start = 2, stop = 5, kind = "gap", source = "masks/gaps.csv"),
            (start = 6, stop = 8, kind = "session", source = "masks/gaps.csv")]
        write(path, "intervals = [[2, 5]]\n")
        @test only(read_gap_intervals(path)).kind == "declared" &&
              only(read_gap_intervals(path)).source == "holes.toml"
    end
end

@testset "Record structure" begin
    contiguous = QuantizedSeries([1.0, 2.0, 3.0, 4.0], 0)
    @test sampling_step(contiguous) == 1 && record_length(contiguous) == 4
    @test observed_mask(contiguous) == trues(4) && segment_lengths(contiguous) == [4]
    @test only(segment_table(contiguous)) ==
          (start = 1, stop = 5, length = 4, kind_before = "", kind_after = "")

    s = declare_gaps(
        QuantizedSeries([1.0, 2.0, 3.0, 4.0, 5.0], 0; times = [0, 250, 500, 1500, 1750],
            cadence = 250),
        [(750, 1500)]; kind = "hole", source = "holes.csv")
    @test s.gaps == [(501, 1500)] && s.gap_kinds == ["hole"]
    @test sampling_step(s) == 250 && record_length(s) == 8
    @test observed_mask(s) == BitVector([1, 1, 1, 0, 0, 0, 1, 1])
    @test segment_lengths(s) == [3, 2] && sum(segment_lengths(s)) == length(s)
    segments = segment_table(s)
    @test segments[1] ==
          (start = 0, stop = 501, length = 3, kind_before = "", kind_after = "hole")
    @test segments[2].kind_before == "hole" && segments[2].kind_after == ""
    @test length(segments) == length(gap_table(s)) + 1
    w(k) = sum(max(L - k, 0) for L in segment_lengths(s))
    @test w(0) == length(s) && w(1) == 3 && w(3) == 0
    @test_throws ArgumentError observed_mask(
        QuantizedSeries(Int32[1, 2, 3], [0, 1, 10^10], 0);
        max_length = 10^6)
    # touching gaps of different kinds between two observations bound one pair of segments
    t2 = declare_gaps(QuantizedSeries(Int32[1, 2], [1, 10], 0),
        [(start = 2, stop = 5, kind = "session", source = ""),
            (start = 5, stop = 10, kind = "hole", source = "")])
    @test segment_lengths(t2) == [1, 1]
    @test [(r.kind_before, r.kind_after) for r in segment_table(t2)] ==
          [("", "session"), ("hole", "")]
end

@testset "Index time axis" begin
    # rows at t = 1 2 3 | closure 4..9 | 10 11 12(missing) 13
    x = Union{Missing, Float64}[1, 2, 3, 4, 5, missing, 7]
    t = Int64[1, 2, 3, 10, 11, 12, 13]
    rs = RawSeries(x, t, :second, nothing, PreparationRecord("rows.csv"))
    elapsed = quantized_series(rs, 0; detect = :cadence, cadence = 1,
        declared = [(start = 4, stop = 10, kind = "session", source = "calendar"),
            (start = 12, stop = 13, kind = "hole", source = "holes.csv")])
    @test elapsed.gaps == [(4, 10), (12, 13)] && elapsed.gap_kinds == ["session", "hole"]
    indexed = index_series(rs, elapsed)
    @test indexed.times == [1, 2, 3, 4, 5, 7] && indexed.time_unit === :sample
    @test indexed.gaps == [(6, 7)] && indexed.gap_kinds == ["hole"] &&
          indexed.gap_sources == ["holes.csv"]
    @test indexed.record.steps[end].op === :index_axis &&
          indexed.record.steps[end].summary["n_closed"] == 1
    # the wait from t = 3 to the first value ≥ 4 crosses the closure of 6 s
    τ_elapsed = waiting_times(elapsed, 1.0)
    τ_index = waiting_times(indexed, 1.0)
    @test τ_elapsed[3] == 7 && τ_index[3] == 1 && τ_elapsed[3] - τ_index[3] == 6

    mktempdir() do dir
        csv = joinpath(dir, "rows.csv")
        CSV.write(csv, DataFrame(t = t, x = x))
        declared = joinpath(dir, "declared.toml")
        write(declared, """
            [[gaps]]
            start = 4
            stop = 10
            kind = "session"
            source = "calendar"
            [[gaps]]
            start = 12
            stop = 13
            kind = "hole"
            source = "holes.csv"
            """)
        handles = Dict(axis =>
                           run_pipeline(axis_config(dir, csv, axis; declared = "declared.toml"))
        for axis in ("elapsed", "index"))
        ce, ci = (load_collection(handles[a].dir) for a in ("elapsed", "index"))
        @test ce.id != ci.id && ce.time_axis === :elapsed && ci.time_axis === :index
        @test ci.metadata["series"]["time_unit_original"] == "second" &&
              ci.metadata["series"]["time_unit"] == "sample" &&
              ci.metadata["series"]["epoch_original"] == DateTime(1970)
        @test isfile(joinpath(ci.dir, "gaps_original.csv")) &&
              !isfile(joinpath(ce.dir, "gaps_original.csv"))
        series_i = CSV.read(joinpath(ci.dir, "series.csv"), DataFrame)
        @test series_i.times == [1, 2, 3, 4, 5, 7] &&
              series_i.time_original == [1, 2, 3, 10, 11, 13] &&
              series_i.row == [1, 2, 3, 4, 5, 7]
        original = CSV.read(joinpath(ci.dir, "gaps_original.csv"), DataFrame)
        @test original.start == [4, 12] && original.kind == ["session", "hole"]
        gaps_e = CSV.read(joinpath(ce.dir, "gaps.csv"), DataFrame)
        @test gaps_e.kind == ["session", "hole"] &&
              gaps_e.source == ["calendar", "holes.csv"]
        de, di = distribution(ce, "1"), distribution(ci, "1")
        @test 7 in WaitingTimes.support(de) && !(7 in WaitingTimes.support(di))
        segments = CSV.read(joinpath(ce.dir, "segments.csv"), DataFrame)
        @test segments.length == [3, 2, 1] && segment_lengths(ce) == [3, 2, 1] &&
              record_length(ce) == 13 && segment_lengths(ci) == [5, 1]
        @test ce.metadata["series"]["n_segments"] == 3 &&
              ce.metadata["series"]["gap_kinds"] == Dict("session" => 1, "hole" => 1)
        # validation on load
        meta = TOML.parsefile(joinpath(ci.dir, "metadata.toml"))
        meta["series"]["time_axis"] = "wallclock"
        open(io -> TOML.print(io, meta), joinpath(ci.dir, "metadata.toml"), "w")
        @test_throws ArgumentError load_collection(ci.dir)
        meta["schema"] = "waitingtimes-provenance/9"
        open(io -> TOML.print(io, meta), joinpath(ci.dir, "metadata.toml"), "w")
        @test_throws ArgumentError load_collection(ci.dir)
        bad = TOML.parsefile(axis_config(dir, csv, "index"))
        bad["input"]["time_axis"] = "wallclock"
        open(io -> TOML.print(io, bad), joinpath(dir, "bad.toml"), "w")
        @test_throws ArgumentError load_settings(joinpath(dir, "bad.toml"))
    end
end

@testset "Per-class partitions and censoring" begin
    mktempdir() do dir
        rng = StableRNG(17)
        n = 4000
        x = Vector{Union{Missing, Float64}}(round.(cumsum(randn(rng, n)); digits = 0))
        x[1001:1100] .= missing
        x[2500:2510] .= missing
        csv = joinpath(dir, "walk.csv")
        CSV.write(csv, DataFrame(t = 1:n, x = x))
        h = run_pipeline(axis_config(dir, csv, "elapsed"))
        c = load_collection(h.dir)
        @test c.metadata["schema"] == "waitingtimes-provenance/3"
        for δ in ("0", "1", "2")
            d = distribution(c, δ)
            cc = WaitingTimes.class_counts(c, δ)
            ch = censoring_histogram(c, δ)
            @test cc.support == WaitingTimes.support(d)
            @test cc.exact .+ cc.gap_crossing == WaitingTimes.counts(d)
            @test sum(cc.exact) == d.n_exact && sum(cc.gap_crossing) == d.n_gap_crossing
            @test sum(ch.count) == d.n_right_censored && issorted(ch.lower)
            # the bounds are those of classify on the stored series
            s = load_series(c)
            class, lower, _ = classify(waiting_times(s, parse_threshold(δ, 0)), s)
            censored = [lower[k]
                        for k in 1:(length(s) - 1) if class[k] == WT.CLASS_RIGHT_CENSORED]
            @test sort(censored) == reduce(vcat, fill.(ch.lower, ch.count))
        end
        @test sum(WaitingTimes.class_counts(c, 1.0).gap_crossing) > 0
        exact = load_collection(run_pipeline(axis_config(dir, csv, "elapsed"; mode = "exact")).dir)
        @test all(iszero, WaitingTimes.class_counts(exact, "1").gap_crossing)
        # the Fenwick sweep serves the thresholds in one pass and agrees
        fenwick = load_collection(run_pipeline(axis_config(dir, csv, "elapsed";
            search = "fenwick_sweep", root = joinpath(dir, "fenwick"))).dir)
        @test fenwick.dir != c.dir && fenwick.id == c.id
        @test all(distribution(fenwick, δ) == distribution(c, δ) for δ in ("0", "1", "2"))
        # a schema-2 partition has no class columns
        entry = c.index[1]
        table = CSV.read(joinpath(c.dir, entry["file"]), DataFrame)
        CSV.write(joinpath(c.dir, entry["file"]), table[:, [
            :tau, :count, :pmf, :cdf, :ccdf]])
        index = TOML.parsefile(joinpath(c.dir, "index.toml"))
        delete!(index["partitions"][1], "censoring_file")
        open(io -> TOML.print(io, index), joinpath(c.dir, "index.toml"), "w")
        old = load_collection(c.dir)
        @test WaitingTimes.class_counts(old, entry["delta"]) === nothing &&
              censoring_histogram(old, entry["delta"]) === nothing
    end
end

@testset "Series round trip, record purity, summaries" begin
    mktempdir() do dir
        x = Union{Missing, Float64}[1.5, 2.25, missing, 3.0, 2.0, 4.5]
        t = [10, 20, 30, 40, 70, 80]
        csv = joinpath(dir, "rt.csv")
        CSV.write(csv, DataFrame(t = t, x = x))
        cfg = TOML.parsefile(axis_config(dir, csv, "elapsed"))
        cfg["quantization"]["digits"] = 2
        cfg["gaps"]["detect"] = "threshold"
        cfg["gaps"]["threshold"] = 10
        cfg["preprocessing"] = Dict("steps" => [Dict("op" => "round", "digits" => 2)])
        path = joinpath(dir, "rt.toml")
        open(io -> TOML.print(io, cfg), path, "w")
        settings = load_settings(path)
        s, _ = prepare(settings)
        c = load_collection(run_pipeline(path).dir)
        loaded = load_series(c)
        @test loaded.values == s.values && eltype(loaded.values) == eltype(s.values)
        @test loaded.times == s.times && loaded.gaps == s.gaps &&
              loaded.gap_kinds == s.gap_kinds && loaded.gap_sources == s.gap_sources
        @test loaded.digits == s.digits && loaded.time_unit === s.time_unit &&
              loaded.epoch == s.epoch == DateTime(1970)
        @test loaded.record.source == s.record.source &&
              loaded.record.source_sha256 == s.record.source_sha256 &&
              [st.op for st in loaded.record.steps] == [st.op for st in s.record.steps]
    end

    record = PreparationRecord("source")
    extended = with_step(record, :op, Dict("a" => 1), Dict("b" => 2))
    @test isempty(record.steps) && length(extended.steps) == 1
    rs = RawSeries(Union{Missing, Float64}[1.234, 2.345], nothing, :sample, nothing,
        PreparationRecord("raw"))
    rounded = round_values(rs; digits = 1)
    @test isempty(rs.record.steps) && rounded.record.steps[end].op === :round
    q = QuantizedSeries(rs.values, 1; record = rs.record)
    @test isempty(rs.record.steps) && q.record.steps[end].op === :quantize

    s = declare_gaps(QuantizedSeries([1.0, 2.0, missing, missing, 3.0, 5.0], 1),
        [(3, 5)]; kind = "hole")
    d = describe(s)
    @test d.n == 4 && d.record_length == 6 && d.first_time == 1 && d.last_time == 6
    @test d.min == 1.0 && d.max == 5.0 && d.mean == 2.75 && d.median == 2.5 &&
          d.digits == 1 && d.sampling_step == 1 && d.n_segments == 2 && d.n_gaps == 1
    @test d.gap_share ≈ 2 / 5 && d.gaps_by_kind["hole"] == (count = 1, share = 2 / 5)
    @test occursin("hole", sprint(show, MIME("text/plain"), d)) &&
          occursin("4 observations", sprint(show, d))
    fig = WaitingTimes.plot_values(QuantizedSeries(round.(randn(StableRNG(3), 500); digits = 2), 2))
    @test fig isa CairoMakie.Figure
    @test WaitingTimes.plot_values(s; bins = 4) isa CairoMakie.Figure
end

@testset "Online estimator over missing samples" begin
    est = OnlineWaitingTimes([1.0], 0)
    push!(est, 1.0)
    push!(est, missing)
    push!(est, 2.0)
    @test est.n_missing == 1 && est.n_seen == 2
    batch = QuantizedSeries([1.0, missing, 2.0], 0)
    τ = waiting_times(batch, 1.0)
    @test WaitingTimes.support(only(snapshot(est))) == [2] && τ[1] == 2
    timed = OnlineWaitingTimes([1.0], 0; time_unit = :second)
    @test_throws ArgumentError push!(timed, missing)
end

@testset "Source and producer identity" begin
    summarise = WaitingTimes.Provenance.source_summary
    dst = Dict{String, Any}("schema" => "deepspacetelemetry-run/1", "run_id" => "r",
        "package_version" => "2.6.2", "git_tree_sha1" => "389a42fa6cd2804ffcfbc4f5bf2ee9c0ce0d174e",
        "git_commit" => "4352f565558d485c8d6cdd624e9ec6f40936aa24", "git_dirty" => false,
        "identity_source" => "manifest")
    s1 = summarise(dst)
    @test s1["producer"] == "DeepSpaceTelemetry" && s1["producer_version"] == "2.6.2" &&
          s1["identity"] && s1["git_commit"] == dst["git_commit"] && !s1["git_dirty"] &&
          s1["producer_compat"] == "2.5.0" && s1["compat_checked"] && s1["compat_satisfied"]
    s1b = summarise(merge(dst,
        Dict("schema" => "deepspacetelemetry-run/2", "package_version" => "3.1.0")))
    @test s1b["producer"] == "DeepSpaceTelemetry" && s1b["producer_version"] == "3.1.0" &&
          s1b["schema"] == "deepspacetelemetry-run/2" && s1b["identity"] &&
          s1b["compat_satisfied"]
    old = Dict{String, Any}(
        "schema" => "deepspacetelemetry-run/1", "package_version" => "2.6.0",
        "git_commit" => "", "git_dirty" => false)
    s2 = summarise(old)
    @test !s2["identity"] && s2["git_tree_sha1"] == "" && s2["compat_satisfied"]
    @test !summarise(merge(old, Dict("package_version" => "2.4.0")))["compat_satisfied"]
    mts = Dict{String, Any}("session" => Dict("id" => "s1", "status" => "completed"),
        "provenance" => Dict("git_commit" => "unknown", "git_dirty" => false,
            "package_version" => "1.0.0", "timestamp_unit" => "nanosecond"))
    s3 = summarise(mts)
    @test s3["producer"] == "MarketTickStreamer" && s3["git_commit"] == "" &&
          !s3["identity"] && s3["producer_compat"] == "1.0.0" && s3["compat_satisfied"]
    @test !summarise(Dict{String, Any}("session" => mts["session"],
        "provenance" => merge(mts["provenance"],
            Dict("package_version" => "0.3.0"))))["compat_satisfied"]
    generic = Dict{String, Any}("producer" => "Other", "producer_version" => "1.2.0",
        "git_tree_sha1" => "abc")
    s4 = summarise(generic)
    @test s4["producer"] == "Other" && s4["identity"] && !s4["compat_checked"] &&
          !s4["compat_satisfied"] && s4["producer_compat"] == ""

    mktempdir() do dir
        csv = joinpath(dir, "id.csv")
        CSV.write(csv, DataFrame(t = 1:200, x = round.(cumsum(randn(StableRNG(5), 200)))))
        cfg = TOML.parsefile(axis_config(dir, csv, "elapsed"))
        descriptor = joinpath(dir, "descriptor.toml")
        open(io -> TOML.print(io, dst), descriptor, "w")
        cfg["input"]["source_descriptor"] = descriptor
        path = joinpath(dir, "id.toml")
        open(io -> TOML.print(io, cfg), path, "w")
        c = load_collection(run_pipeline(path).dir)
        summary = WaitingTimes.source_summary(c)
        @test summary.producer == "DeepSpaceTelemetry" && summary.identity &&
              summary.git_tree_sha1 == dst["git_tree_sha1"] && summary.compat_satisfied
        @test source_descriptor(c) == dst
        producer = c.metadata["producer"]
        @test producer["name"] == "WaitingTimes" &&
              producer["version"] == string(pkgversion(WaitingTimes))
        @test producer["identity_source"] in ("work_tree", "manifest", "directory") &&
              length(producer["git_tree_sha1"]) == 40 && producer["git_dirty"] isa Bool
        environment = c.metadata["environment"]
        snapshot = joinpath(c.dir, environment["manifest_file"])
        @test isfile(snapshot) &&
              environment["manifest_sha256"] ==
              WaitingTimes.Provenance.file_sha256(snapshot)
        session = TOML.parsefile(joinpath(c.dir, "sessions",
            c.metadata["sessions"][1]["id"] * ".toml"))
        @test session["producer"]["git_tree_sha1"] == producer["git_tree_sha1"] &&
              session["manifest_sha256"] == environment["manifest_sha256"]
        @test isfile(joinpath(c.dir, "sessions", session["id"] * ".manifest.toml"))
        # a collection written before the summary was stored computes it from the descriptor
        meta = TOML.parsefile(joinpath(c.dir, "metadata.toml"))
        foreach(k -> delete!(meta["source"], k), ("producer", "identity", "git_tree_sha1"))
        open(io -> TOML.print(io, meta), joinpath(c.dir, "metadata.toml"), "w")
        @test WaitingTimes.source_summary(load_collection(c.dir)).git_tree_sha1 ==
              dst["git_tree_sha1"]
        # an unsupported producer version is recorded, with a warning
        open(io -> TOML.print(io, merge(dst, Dict("package_version" => "2.4.0"))),
            descriptor, "w")
        cfg["output"]["root"] = joinpath(dir, "old")
        open(io -> TOML.print(io, cfg), path, "w")
        older = @test_logs (:warn, r"producer version") match_mode = :any run_pipeline(path)
        @test !WaitingTimes.source_summary(load_collection(older.dir)).compat_satisfied
    end
end
