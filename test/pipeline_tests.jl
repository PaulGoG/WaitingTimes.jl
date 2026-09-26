# Phase 3 tests: provenance, configuration, naming, preprocessing, storage,
# orchestration and the package extensions.

using WaitingTimes.Provenance: artefact_id, backup_existing!, canonical_toml, content_hash,
                               dict_to_record, effective_config, record_to_dict, slugify,
                               toml_ready, write_toml
using WaitingTimes.Naming: artefact_name, parse_artefact_name
using WaitingTimes.Preprocessing: RawSeries, apply_steps, centered_moving_average,
                                  clip_extremes, clip_quantile, clip_sigma, collapse_ties,
                                  differences,
                                  exclude_intervals, log_returns, quantized_series,
                                  read_series, resolution_digits, round_values,
                                  sampling_summary, select_range, terminal_overview,
                                  trailing_mean_fluctuations, value_summary
using WaitingTimes.Storage: load_distributions, partition_path, read_distribution,
                            read_index, read_series_files, write_distribution,
                            write_series_files
using WaitingTimes.Orchestrator: estimate_memory_bytes, make_kernel
using WaitingTimes.Config: KNOWN_KEYS
using CSV: CSV
using DataFrames: DataFrame, nrow
using Dates: DateTime
using TOML: TOML
using Logging: Warn
using Statistics: std
import Distributions
using CairoMakie: CairoMakie

const CONFIGS = joinpath(dirname(@__DIR__), "configs")

function raw_from(values; times = nothing, unit = :sample)
    RawSeries(Vector{Union{Missing, Float64}}(values), times,
        unit, nothing, PreparationRecord("test"))
end

@testset "Provenance" begin
    a = Dict("b" => 1, "a" => [1, 2], "c" => Dict("z" => :sym, "y" => nothing))
    b = Dict("c" => Dict("y" => nothing, "z" => :sym), "a" => [1, 2], "b" => 1)
    @test canonical_toml(a) == canonical_toml(b)
    @test content_hash(a) == content_hash(b)
    @test content_hash(Dict("b" => 2)) != content_hash(Dict("b" => 1))
    @test toml_ready((x = 1, y = :z)) == Dict("x" => 1, "y" => "z")
    @test toml_ready((1, 2)) == [1, 2]
    @test slugify("geisenheim wind speed (km/h)") == "geisenheim_wind_speed_km_h"
    @test_throws ArgumentError slugify("   ")
    id = artefact_id("collection", "geisenheim wind", Dict("k" => 1))
    @test startswith(id, "collection-geisenheim_wind-") &&
          length(id) == length("collection-geisenheim_wind-") + 8
    mktempdir() do dir
        path = joinpath(dir, "f.txt")
        write(path, "one")
        backup_existing!(path)
        write(path, "two")
        backup_existing!(path)
        @test isfile(joinpath(dir, "f#1.txt")) && isfile(joinpath(dir, "f#2.txt"))
        base = joinpath(dir, "base.toml")
        overlay = joinpath(dir, "overlay.toml")
        write(base, "[input]\npath = \"a\"\nformat = \"csv\"\n[gaps]\ncadence = 1\n")
        write(overlay, "base_config = \"base.toml\"\n[input]\nformat = \"dat\"\n")
        cfg = effective_config(overlay)
        @test cfg["input"]["path"] == "a" && cfg["input"]["format"] == "dat"
        @test cfg["gaps"]["cadence"] == 1 && !haskey(cfg, "base_config")
        write(joinpath(dir, "bad.toml"), "base_config = \"missing.toml\"\n")
        @test_throws ArgumentError effective_config(joinpath(dir, "bad.toml"))
        write(joinpath(dir, "chain.toml"), "base_config = \"overlay.toml\"\n")
        @test_throws ArgumentError effective_config(joinpath(dir, "chain.toml"))
    end
    record = PreparationRecord("source"; sha256 = "abc")
    WaitingTimes.record!(record, :op, Dict{String, Any}("w" => 3), Dict{String, Any}("n" =>
        4))
    back = dict_to_record(record_to_dict(record))
    @test back.source == "source" && back.source_sha256 == "abc"
    @test back.steps[1].op === :op && back.steps[1].parameters["w"] == 3
end

@testset "Configuration" begin
    settings = load_settings(joinpath(CONFIGS, "quickstart.toml"))
    @test settings.input_format === :dat && settings.digits == 4
    @test settings.value_column == "Data" && settings.time_column === nothing
    @test settings.threshold_mode === :linear && settings.search === :segment_tree
    @test isfile(settings.input_path)
    @test endswith(settings.output_root, "data")
    s = QuantizedSeries([1.0, 2.0], 4)
    ts = threshold_list(settings, s)
    @test length(ts) == 10 && format_threshold(first(ts)) == "0.0005" &&
          format_threshold(last(ts)) == "0.0050"
    mktempdir() do dir
        base_dict = Dict{String, Any}(
            "input" => Dict{String, Any}("path" => settings.input_path, "format" => "dat",
                "value_column" => "Data"),
            "quantization" => Dict{String, Any}("digits" => 4),
            "thresholds" => Dict{String, Any}("mode" => "linear", "min" => 0.0005,
                "max" => 0.005, "step" => 0.0005))
        write_config(extra) = begin
            path = joinpath(dir, "c.toml")
            merged = WaitingTimes.Provenance.merge_config(base_dict, extra)
            open(path, "w") do io
                TOML.print(io, merged)
            end
            path
        end
        D(pairs...) = Dict{String, Any}(pairs...)
        @test_logs (:warn, r"unknown configuration key") match_mode = :any load_settings(write_config(D("input" =>
            D("unknown" => 1))))
        @test_throws ArgumentError load_settings(write_config(D("thresholds" =>
            D("mode" => "linear", "min" => 1.0, "max" => 0.5, "step" => 0.1))))
        @test_throws ArgumentError load_settings(write_config(D("thresholds" =>
            D("mode" => "explicit"))))
        @test_throws ArgumentError load_settings(write_config(D("thresholds" =>
            D("min" => 0.00001, "max" => 1.0, "step" => 0.1))))
        @test_throws ArgumentError load_settings(write_config(D("algorithm" =>
            D("search" => "quantum"))))
        @test load_settings(write_config(D("algorithm" => D("search" => "device")))).search ===
              :device
        @test_throws ArgumentError load_settings(write_config(D("gaps" =>
            D("detect" => "threshold"))))
        @test_throws ArgumentError load_settings(write_config(D("input" =>
            D("time_column" => "Time"))))
        @test_throws ArgumentError load_settings(write_config(D("preprocessing" =>
            D("steps" => Any[D("op" => "teleport")]))))
        @test_throws ArgumentError load_settings(write_config(D("preprocessing" =>
            D("steps" => Any[D("op" => "clip_quantile", "q" => 1.5)]))))
        @test_throws ArgumentError load_settings(write_config(D("preprocessing" =>
            D("steps" => Any[D("op" => "trailing_mean_fluctuations", "window" => 5,
                "denominator" => "scale", "offset" => "auto")]))))
        @test_throws ArgumentError load_settings(write_config(D("preprocessing" =>
            D("steps" => Any[D("op" => "centered_moving_average", "window" => 4)]))))
        @test_throws ArgumentError load_settings(write_config(D("preprocessing" =>
            D("steps" => Any[D("op" => "round", "digits" => 16)]))))
        @test length(load_settings(write_config(D("preprocessing" =>
            D("steps" =>
                Any[D("op" => "clip_sigma", "k" => 2.5, "center" => "median",
                    "scale" => "mad", "splice" => false)])))).steps) == 1
        log_settings = load_settings(write_config(D("thresholds" =>
            D("mode" => "log", "min" => 0.001, "max" => 1.0, "points_per_decade" => 3))))
        ts = threshold_list(log_settings, s)
        @test issorted([t.d for t in ts]) && allunique(ts) && first(ts).d == 10 &&
              last(ts).d == 10_000
        explicit = load_settings(write_config(D("thresholds" =>
            D("mode" => "explicit", "values" => [0.5, 0.0005, 0.5]))))
        @test [format_threshold(t) for t in threshold_list(explicit, s)] ==
              ["0.0005", "0.5000"]
        @test_throws ArgumentError load_settings(joinpath(dir, "absent.toml"))
    end
    @test "input" in KNOWN_KEYS[""]
end

@testset "Naming" begin
    name = artefact_name(; series = "geisenheim-wind_speed+clip0.996", model = "SF",
        representation = "ccdf", binning = "log5", delta = "1.0", id = "f3a91c2e", ext = "pdf",
        extras = ["panel" => "A"])
    @test name ==
          "geisenheim-wind_speed+clip0.996__SF__ccdf__log5__delta=1.0__panel=A__f3a91c2e.pdf"
    parsed = parse_artefact_name(joinpath("some", "dir", name))
    @test parsed.series == "geisenheim-wind_speed+clip0.996" && parsed.model == "SF"
    @test parsed.representation == "ccdf" && parsed.binning == "log5" &&
          parsed.delta == "1.0"
    @test parsed.extras == Dict("panel" => "A") && parsed.id == "f3a91c2e" &&
          parsed.ext == "pdf"
    @test_throws ArgumentError parse_artefact_name("a__b.pdf")
    @test_throws ArgumentError parse_artefact_name("a__b__c__d__e__f")
    @test_throws ArgumentError artefact_name(;
        series = "s", representation = "pdf", delta = "1",
        id = "x", ext = "pdf", extras = ["delta" => "2"])
end

@testset "Preprocessing" begin
    rs = raw_from([1.0, 2.0, missing, 4.0, 8.0])
    @test sampling_summary(rs).n_missing == 1
    @test value_summary(rs).max == 8.0
    d = differences(rs)
    @test isequal(d.values, [missing, 1.0, missing, 2.0, 4.0])
    lr = log_returns(raw_from([1.0, 2.0, 4.0]))
    @test lr.values[2] ≈ 100 * log(2) && lr.values[3] ≈ 100 * log(2) &&
          ismissing(lr.values[1])
    @test_throws ArgumentError log_returns(raw_from([1.0, -1.0]))
    tm = trailing_mean_fluctuations(raw_from([10.0, 11.0, 12.0, 6.0]); window = 2)
    @test tm.values[1] == 0.0 && tm.values[2] ≈ 10.0 &&
          tm.values[3] ≈ (12 - 10.5) * 100 / 10.5
    @test tm.values[4] ≈ (6 - 11.5) * 100 / 11.5
    @test_throws ArgumentError trailing_mean_fluctuations(raw_from([0.0, 1.0]); window = 1)
    # the papers' shift: the minimum becomes 1 before the percentage
    sh = trailing_mean_fluctuations(raw_from([-4.0, 1.0, 6.0]); window = 1, offset = :auto)
    @test sh.record.steps[end].summary["shift"] == 5.0
    @test sh.values[2] ≈ (6 - 1) * 100 / 1 && sh.values[3] ≈ (11 - 6) * 100 / 6
    num = trailing_mean_fluctuations(raw_from([-4.0, 1.0]); window = 1, offset = 10)
    @test num.values[2] ≈ (11 - 6) * 100 / 6
    @test_throws ArgumentError trailing_mean_fluctuations(raw_from([1.0, 2.0]); window = 1,
        denominator = :scale, offset = :auto)
    @test_throws ArgumentError trailing_mean_fluctuations(raw_from([1.0, 2.0]); window = 1,
        denominator = :ratio)
    # absolute deviations and scale-normalised deviations
    ab = trailing_mean_fluctuations(raw_from([1.0, 3.0, 2.0, 6.0]); window = 2,
        denominator = :none)
    @test ab.values == [0.0, 2.0, 0.0, 3.5]
    sc = trailing_mean_fluctuations(raw_from([1.0, 3.0, 2.0, 6.0]); window = 2,
        denominator = :scale)
    dev = [2.0, 0.0, 3.5]
    @test sc.values[2:end] ≈ dev ./ std(dev) && sc.values[1] == 0.0
    @test_throws ArgumentError trailing_mean_fluctuations(
        raw_from([1.0, 1.0, 1.0]); window = 1,
        denominator = :scale)
    # non-positive trailing mean: abort, or record as missing
    @test_throws ArgumentError trailing_mean_fluctuations(raw_from([1.0, -1.0, 2.0]); window = 1)
    np = trailing_mean_fluctuations(raw_from([1.0, -1.0, 2.0]); window = 1,
        on_nonpositive = :missing)
    @test isequal(np.values, [0.0, -200.0, missing]) &&
          np.record.steps[end].summary["n_nonpositive"] == 1
    # rounding step
    rd = round_values(raw_from([1.26, missing, 2.35]); digits = 1)
    @test isequal(rd.values, [1.3, missing, 2.4])
    @test_throws ArgumentError round_values(rd; digits = 16)
    cma = centered_moving_average(raw_from([1.0, 2.0, 3.0, 4.0, 5.0]); window = 3)
    @test cma.values[3] == 0.0 && cma.values[1] ≈ 1 - 1.5
    @test_throws ArgumentError centered_moving_average(rs; window = 2)
    # pruning keeps the slot by default (the 2024 semantics); splice deletes it
    cq2 = clip_quantile(raw_from([1.0, 2.0, 3.0, 100.0]); q = 0.75)
    @test isequal(cq2.values, [1.0, 2.0, 3.0, missing])
    @test cq2.record.steps[end].summary["n_removed"] == 1 &&
          cq2.record.steps[end].summary["positions"] == [4] &&
          cq2.record.steps[end].parameters["splice"] == false
    cq = clip_quantile(raw_from([1.0, 2.0, 3.0, 100.0]); q = 0.75, splice = true)
    @test cq.values == [1.0, 2.0, 3.0] && cq.times === nothing
    timed = raw_from([1.0, 50.0, 2.0, 3.0, 60.0, 4.0]; times = [1, 2, 4, 7, 11, 16], unit = :second)
    ct = clip_quantile(timed; q = 0.6, splice = true)
    @test ct.values == [1.0, 2.0, 3.0, 4.0] && ct.times == [1, 3, 6, 11]
    # consecutive removals close their slots cumulatively
    ct2 = clip_quantile(
        raw_from([1.0, 50.0, 60.0, 2.0]; times = [1, 2, 4, 8], unit = :second);
        q = 0.5, splice = true)
    @test ct2.values == [1.0, 2.0] && ct2.times == [1, 5]
    # removing the first row drops it without shifting
    ct3 = clip_quantile(
        raw_from([50.0, 1.0, 2.0]; times = [1, 3, 4], unit = :second); q = 0.6,
        splice = true)
    @test ct3.values == [1.0, 2.0] && ct3.times == [3, 4]
    # a spanning waiting time shortens by the removed slots when spliced, and keeps
    # its elapsed length when the slot stays
    spliced = quantized_series(
        clip_quantile(raw_from([1.0, 2.0, 9.0, 9.0, 3.0]); q = 0.6,
            splice = true), 0)
    @test spliced.times == [1, 2, 3] && waiting_times(spliced, 2) == [2, 0, 0]
    kept = quantized_series(clip_quantile(raw_from([1.0, 2.0, 9.0, 9.0, 3.0]); q = 0.6), 0)
    @test kept.times == [1, 2, 5] && kept.gaps == [(3, 5)] &&
          waiting_times(kept, 2) == [4, 0, 0]
    @test_throws ArgumentError clip_quantile(raw_from([1.0, 2.0]); q = 0.0)
    cs = clip_sigma(raw_from([0.0, 0.1, -0.1, 0.05, 100.0]); k = 1, splice = true)
    @test cs.values == [0.0, 0.1, -0.1, 0.05]
    cs_robust = clip_sigma(
        raw_from([0.0, 0.1, -0.1, 0.05, 100.0]); k = 3, center = :median,
        scale = :mad)
    @test isequal(cs_robust.values, [0.0, 0.1, -0.1, 0.05, missing]) &&
          cs_robust.record.steps[end].parameters["center"] == "median"
    @test_throws ArgumentError clip_sigma(raw_from([1.0, 1.0]); k = 3)
    # the 2024 pruning loop removes whole magnitude levels until the fraction is reached
    ce = clip_extremes(raw_from([1.0, 9.7, 2.0, 9.2, -9.9, 3.0, 4.0, 5.0, 6.0, 7.0]);
        fraction = 0.25, digits = 0, splice = true)
    @test ce.values == [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0]
    @test ce.record.steps[end].summary["passes"] == 1 &&
          ce.record.steps[end].summary["n_removed"] == 3
    ce2 = clip_extremes(raw_from([1.0, 9.7, 2.0, 9.2, -9.9, 3.0, 4.0, 5.0, 6.0, 7.0]);
        fraction = 0.35, digits = 1)
    @test isequal(ce2.values, [
        1.0, missing, 2.0, missing, missing, 3.0, 4.0, 5.0, 6.0, missing]) &&
          ce2.record.steps[end].summary["passes"] == 2
    @test_throws ArgumentError clip_extremes(raw_from([1.0, 2.0]); fraction = 1.0, digits = 0)
    @test_throws ArgumentError clip_sigma(raw_from([1.0, 2.0]); k = 0)
    @test_throws ArgumentError clip_sigma(raw_from([1.0, 2.0]); center = :mode)
    sr = select_range(raw_from([1.0, 2.0, 3.0, 4.0]); from = 2, to = 3)
    @test sr.values == [2.0, 3.0]
    @test_throws ArgumentError select_range(rs; from = 10, to = 20)
    # surgical cut with splice closes the time axis
    ex = exclude_intervals(
        raw_from([1.0, 2.0, 3.0, 4.0, 5.0]; times = [1, 2, 3, 4, 10], unit = :second),
        [(2, 4)])
    @test ex.values == [1.0, 4.0, 5.0] && ex.times == [1, 2, 8]
    ex2 = exclude_intervals(raw_from([1.0, 2.0, 3.0]), [(2, 3)]; splice = false)
    @test isequal(ex2.values, [1.0, missing, 3.0])
    @test_throws ArgumentError exclude_intervals(rs, [(3, 2)])
    # ties
    tied = raw_from([1.0, 2.0, 3.0, 4.0]; times = [1, 1, 2, 2], unit = :second)
    @test_throws ArgumentError collapse_ties(tied, :error)
    @test collapse_ties(tied, :last).values == [2.0, 4.0]
    @test collapse_ties(tied, :first).values == [1.0, 3.0]
    @test collapse_ties(tied, :mean).values == [1.5, 3.5] &&
          collapse_ties(tied, :mean).times == [1, 2]
    # apply_steps and quantisation
    stepped = apply_steps(raw_from([1.0, 2.0, 4.0, 8.0]),
        [Dict("op" => "log_returns"), Dict("op" => "clip_quantile", "q" => 1.0)])
    @test length(stepped.record.steps) == 2
    paper = apply_steps(raw_from([-4.26, 1.0, 6.04, 2.0]),
        [Dict("op" => "round", "digits" => 1),
            Dict("op" => "trailing_mean_fluctuations",
                "window" => 1, "denominator" => "mean",
                "offset" => "auto"),
            Dict("op" => "clip_sigma", "k" => 1.0, "center" => "median", "scale" => "mad",
                "splice" => true)])
    @test [st.op for st in paper.record.steps] ==
          [:round, :trailing_mean_fluctuations, :clip_sigma]
    @test_throws ArgumentError apply_steps(raw_from([1.0, 2.0]), [Dict("op" => "warp")])
    @test_throws ArgumentError WaitingTimes.Preprocessing.check_finite(raw_from([1.0, Inf]), "x")
    qs = quantized_series(stepped, 2; detect = :cadence, cadence = 1)
    @test qs.times == [1, 2, 3] && isempty(qs.gaps) && qs.digits == 2
    qs2 = quantized_series(raw_from([1.0, missing, 2.0]), 0; detect = :none)
    @test isempty(qs2.gaps) && qs2.times == [1, 3]
    qs3 = quantized_series(raw_from([1.0, 2.0, 3.0]; times = [1, 5, 9], unit = :second), 0;
        detect = :threshold, threshold = 2, declared = [(6, 8)])
    @test qs3.gaps == [(2, 5), (6, 9)]
    @test_throws ArgumentError quantized_series(rs, 0; detect = :undefined)
    # recorded resolution
    @test resolution_digits(raw_from([1.0857, 1.0900, 12.0])) == 4
    @test resolution_digits(raw_from([3.0, 5.0, missing])) == 0
    @test resolution_digits(raw_from([0.1, 0.2, 0.3])) == 1
    @test resolution_digits(raw_from([1 / 3, 2 / 3])) === nothing
    @test resolution_digits(raw_from([1 / 3, 2 / 3]); max_digits = 15, tolerance = 1.0) == 0
    @test_throws ArgumentError resolution_digits(raw_from([1.0]); max_digits = 16)
    @test_throws ArgumentError resolution_digits(raw_from([missing, missing]))
    io = IOBuffer()
    terminal_overview(io, raw_from(sin.(1:200)))
    @test occursin("value", String(take!(io)))
    # ingestion
    mktempdir() do dir
        csv = joinpath(dir, "series.csv")
        write(csv,
            "stamp,value,label\n2020-01-01T00:00:00,1.5,a\n2020-01-01T01:00:00,,b\n2020-01-01T03:00:00,2.5,c\n")
        rs_csv = read_series(csv; value_column = "value", time_column = "stamp", time_unit = :hour)
        @test isequal(rs_csv.values, [1.5, missing, 2.5]) &&
              rs_csv.times[2] - rs_csv.times[1] == 1 &&
              rs_csv.times[3] - rs_csv.times[1] == 3
        @test rs_csv.epoch == DateTime(1970)
        @test_throws ArgumentError read_series(csv; value_column = "value", missing_policy = :error)
        @test_throws ArgumentError read_series(csv; value_column = "nope")
        @test_throws ArgumentError read_series(csv; value_column = 7)
        @test_throws ArgumentError read_series(
            csv; value_column = "value", time_column = "stamp", time_unit = :day)
        @test_throws ArgumentError read_series(csv; value_column = "value", time_column = "stamp")
        tick = joinpath(dir, "ticks.csv")
        write(tick,
            "symbol,time_ns,price,size\nX,1000000000,10.0,1\nX,1000000000,10.5,2\nX,2500000000,11.0,1\n")
        rs_tick = read_series(tick; format = :tick, value_column = "price", tie_policy = :last)
        @test rs_tick.time_unit === :nanosecond && rs_tick.values == [10.5, 11.0]
        @test_throws ArgumentError read_series(tick; format = :tick, value_column = "price")
        by_index = read_series(
            joinpath(dirname(@__DIR__), "test", "fixtures", "fiatEURUSD.dat");
            value_column = 2)
        @test length(by_index) == 11572 && by_index.record.steps[1].op === :read_series
        @test_throws ArgumentError read_series(joinpath(dir, "absent.csv"); value_column = 1)
        @test_throws ArgumentError read_series(joinpath(dir, "x.bin"); value_column = 1)
    end
end

@testset "Storage" begin
    rng = StableRNG(5)
    s = QuantizedSeries(rounded_walk(rng, 2_000), 2)
    δ = threshold(0.5, s)
    d = empirical_distribution(waiting_times(s, δ), δ, s)
    mktempdir() do dir
        for format in (:csv, :arrow)
            path = partition_path(dir, δ, format)
            @test endswith(path, "delta=0.50." * String(format))
            sha = write_distribution(path, d, format; metadata = Dict("collection" => "c", "delta" => "0.50"))
            @test length(sha) == 64
            table = read_distribution(path)
            @test table.tau == WaitingTimes.support(d) &&
                  table.count == WaitingTimes.counts(d)
            @test table.ccdf ≈ WaitingTimes.survival(d)
            series_path, gaps_path = write_series_files(joinpath(dir, String(format)), s, format)
            back = read_series_files(joinpath(dir, String(format)), s.digits, s.time_unit)
            @test back.values == s.values && back.times == s.times && back.gaps == s.gaps
        end
        @test isempty(read_index(dir))
        @test nrow(load_distributions(dir)) == 0
    end
end

@testset "Orchestration end to end" begin
    mktempdir() do dir
        settings = load_settings(joinpath(CONFIGS, "quickstart.toml"); output_dir = dir)
        @test settings.output_root == dir
        @test make_kernel(settings) isa SegmentTreeSearch
        series, ids = prepare(settings)
        @test length(series) == 11572 &&
              startswith(ids.series_id, "series-eur_usd-closing_rate-")
        @test estimate_memory_bytes(series, make_kernel(settings)) > 0
        handle = generate(settings)
        @test isdir(handle.dir) && startswith(handle.id, "collection-eur_usd-closing_rate-")
        @test length(handle.computed) == 10 && isempty(handle.skipped)
        @test length(handle.reference_checks) == 2 &&
              all(c -> c["equal"] && c["work"] > 0, handle.reference_checks)
        for name in ("config.toml", "metadata.toml", "hardware.txt", "index.toml", "summary.csv",
            "catalog.csv", "series.csv", "gaps.csv", "series.toml", "run.log")
            @test isfile(joinpath(handle.dir, name))
        end
        @test isfile(joinpath(handle.dir, "distributions", "delta=0.0005.csv"))
        meta = TOML.parsefile(joinpath(handle.dir, "metadata.toml"))
        @test meta["artefact"]["id"] == handle.id && length(meta["sessions"]) == 1
        @test meta["dataset"]["descriptor"]["slug"] == "eur_usd-closing_rate"
        session = TOML.parsefile(joinpath(handle.dir, "sessions", handle.session * ".toml"))
        @test isfile(joinpath(handle.dir, "sessions", handle.session * ".config.toml"))
        @test session["kernel"] == "segmenttreesearch" &&
              length(session["deltas_computed"]) == 10
        @test haskey(session["timings"], "search") &&
              session["hardware"]["threads"] == Threads.nthreads()
        # the partition reproduces the legacy fixture
        legacy = read_legacy_table(joinpath(FIXTURES, "legacy", "WTS_ftEURUSD_clsng_raw_deltais0.0005.dat"))
        table = read_distribution(joinpath(handle.dir, "distributions", "delta=0.0005.csv"))
        @test table.tau == parse.(Int, legacy["time"])
        @test table.pmf ≈ parse.(Float64, legacy["pdf"]) atol = 1e-12
        long = load_distributions(handle.dir; deltas = ["0.0005", "0.0010"])
        @test Set(long.delta) == Set(["0.0005", "0.0010"])
        summary = CSV.read(joinpath(handle.dir, "summary.csv"), DataFrame)
        @test nrow(summary) == 10 && summary.n_candidates[1] == 11571
        # second run: everything skipped, session appended
        again = generate(settings)
        @test again.id == handle.id && isempty(again.computed) &&
              length(again.skipped) == 10
        @test length(TOML.parsefile(joinpath(handle.dir, "metadata.toml"))["sessions"]) == 2
        # extension of the grid adds partitions without touching existing ones
        wider = load_settings(joinpath(CONFIGS, "quickstart.toml"); output_dir = dir)
        raw = copy(wider.raw)
        mktempdir() do cdir
            cfg = joinpath(cdir, "wider.toml")
            base = TOML.parsefile(joinpath(CONFIGS, "quickstart.toml"))
            base["input"]["path"] = settings.input_path
            base["thresholds"]["max"] = 0.006
            base["output"]["root"] = dir
            open(cfg, "w") do io
                TOML.print(io, base)
            end
            third = run_pipeline(cfg)
            @test third.id == handle.id && third.computed == ["0.0055", "0.0060"] &&
                  length(third.skipped) == 10
            @test length(read_index(handle.dir)) == 12
            # overwrite backs up
            base["output"]["overwrite"] = true
            base["thresholds"]["max"] = 0.001
            open(cfg, "w") do io
                TOML.print(io, base)
            end
            fourth = run_pipeline(cfg)
            @test length(fourth.computed) == 2
            @test isfile(joinpath(handle.dir, "distributions", "delta=0.0005#1.csv"))
        end
        # the read side: collection object, distributions, legacy export
        @test isfile(joinpath(handle.dir, "README.md")) &&
              occursin("delta=", read(joinpath(handle.dir, "README.md"), String))
        c = load_collection(handle.dir)
        @test c.id == handle.id && c.digits == 4 && c.time_unit === :sample &&
              c.mode === :elapsed && c.n_observations == 11572 && isempty(c.steps)
        @test length(thresholds(c)) == 12 && first(thresholds(c)) == Threshold(5, 4)
        d = distribution(c, "0.0005")
        @test d == distribution(c, 0.0005) == distribution(c, Threshold(5, 4))
        @test WaitingTimes.support(d) == parse.(Int, legacy["time"]) &&
              d.n_candidates == 11571 && d.delta == Threshold{Int64}(5, 4)
        @test_throws ArgumentError distribution(c, "0.0007")
        @test_throws ArgumentError distribution(c, Threshold(5, 3))
        st = summary_table(c)
        @test nrow(st) == 12 && st.delta[1] == "0.0005"
        loaded = load_series(c)
        @test length(loaded) == 11572 && loaded.digits == 4
        listing = list_collections(dir)
        @test nrow(listing) == 1 && listing.id[1] == handle.id &&
              listing.n_thresholds[1] == 12
        @test isempty(list_collections(joinpath(dir, "absent")))
        @test occursin("thresholds  12", sprint(show, MIME("text/plain"), c))
        @test_throws ArgumentError load_collection(dir)
        mktempdir() do out
            paths = export_legacy(c, out; slug = "ftEURUSD_clsng_raw")
            @test length(paths) == 12
            exported = joinpath(out, "WTS_ftEURUSD_clsng_raw_deltais0.0005.dat")
            @test read(exported, String) ==
                  read(joinpath(FIXTURES, "legacy", "WTS_ftEURUSD_clsng_raw_deltais0.0005.dat"), String)
        end
        report = validate(settings; deltas = [0.001, 0.005])
        @test report["all_equal"] && length(report["results"]) == 2
        @test all(r -> r["n_differences"] == 0, report["results"])
        report2 = validate(settings)
        @test report2["all_equal"] && length(report2["results"]) == 2
    end
end

@testset "Distributions extension" begin
    rng = StableRNG(9)
    s = QuantizedSeries(rounded_walk(rng, 3_000), 2)
    δ = threshold(1.0, s)
    d = empirical_distribution(waiting_times(s, δ), δ, s)
    dn = WaitingTimes.discrete_distribution(d)
    @test dn isa Distributions.DiscreteNonParametric
    @test Distributions.support(dn) == WaitingTimes.support(d)
    @test Distributions.probs(dn) ≈ WaitingTimes.probabilities(d)
    @test Distributions.cdf(dn, maximum(WaitingTimes.support(d))) ≈ 1.0
    @test Distributions.DiscreteNonParametric(d) isa Distributions.DiscreteNonParametric
    empty = empirical_distribution(zeros(Int64, length(s)), δ, s)
    @test_throws ArgumentError WaitingTimes.discrete_distribution(empty)
end

@testset "CairoMakie extension" begin
    rng = StableRNG(10)
    x = Vector{Union{Missing, Float64}}(rounded_walk(rng, 5_000))
    x[100:120] .= missing
    s = QuantizedSeries(x, 2)
    δ = threshold(1.0, s)
    d = empirical_distribution(waiting_times(s, δ), δ, s)
    @test WaitingTimes.figure_theme() isa CairoMakie.Theme
    @test WaitingTimes.decade_ticks(-1, 2) ==
          ([0.1, 1.0, 10.0, 100.0], ["10⁻¹", "1", "10", "10²"])
    @test_throws ArgumentError WaitingTimes.decade_ticks(2, 1)
    fig = WaitingTimes.plot_series(s; quantity_label = "level", unit_label = "cm")
    @test fig isa CairoMakie.Figure
    fig2 = WaitingTimes.plot_distribution(d)
    @test fig2 isa CairoMakie.Figure
    mktempdir() do dir
        path = joinpath(dir, "figures", "series.png")
        WaitingTimes.save_figure(path, fig; sidecar = Dict("kind" => "series", "delta" => "1.00"))
        @test isfile(path) && isfile(path * ".toml")
        @test TOML.parsefile(path * ".toml")["delta"] == "1.00"
        pdf = joinpath(dir, "distribution.pdf")
        WaitingTimes.save_figure(pdf, fig2; sidecar = Dict("kind" => "distribution"))
        @test isfile(pdf)
    end
    empty = empirical_distribution(zeros(Int64, length(s)), δ, s)
    @test_throws ArgumentError WaitingTimes.plot_distribution(empty)
end
