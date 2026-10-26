# Paths not exercised elsewhere: reading a collection of provenance schema 2,
# the dense waiting-time files, the limit guards, reference checks run with the
# guarded and device kernels, and the absorption and merging of gaps of several
# kinds.

using CSV: CSV
using DataFrames: DataFrame, nrow
using TOML: TOML

# The series of `fixtures/schema2`: 20 samples, samples 9 and 10 missing.
const CONTRACT_TIMES = [1:8; 11:20]
const CONTRACT_VALUES = [3, 4, 2, 5, 5, 3, 6, 4, 7, 5, 8, 6, 6, 9, 7, 8, 10, 9]
# Its waiting times and classes at δ = 1 and δ = 3, from the definition.
const CONTRACT_TAU = Dict(
    "1" => [1, 2, 1, 3, 2, 1, 4, 3, 2, 1, 3, 2, 1, 3, 1, 1, 0, 0],
    "3" => [6, 9, 1, 9, 8, 1, 9, 3, 8, 1, 0, 2, 1, 0, 2, 0, 0, 0])
const CONTRACT_CLASS = let E = WT.CLASS_EXACT, G = WT.CLASS_GAP_CROSSING,
    C = WT.CLASS_RIGHT_CENSORED

    Dict("1" => [E, E, E, E, E, E, G, G, E, E, E, E, E, E, E, E, C, C],
        "3" => [E, G, E, G, G, E, G, G, E, E, C, E, E, C, E, C, C, C])
end

"the series of `fixtures/schema2` as `dir/contract.csv` (`n`, `x`; `x` empty if missing)"
function contract_csv(dir::AbstractString)
    x = Vector{Union{Missing, Float64}}(missing, 20)
    x[CONTRACT_TIMES] .= CONTRACT_VALUES
    path = joinpath(dir, "contract.csv")
    CSV.write(path, DataFrame(n = 1:20, x = x))
    return path
end

"""
Configuration `dir/<name>.toml` for `csv` on the sample axis at δ = 1 and 3, with
its collection under `dir/<name>`; the given tables are merged over the defaults.
"""
function contract_config(dir::AbstractString, csv::AbstractString, name::AbstractString;
        algorithm = Dict{String, Any}(), limits = Dict{String, Any}(),
        output = Dict{String, Any}())
    cfg = Dict{String, Any}(
        "input" => Dict{String, Any}("path" => csv, "format" => "csv",
            "value_column" => "x"),
        "gaps" => Dict{String, Any}("detect" => "cadence", "cadence" => 1),
        "quantization" => Dict{String, Any}("digits" => 0),
        "thresholds" => Dict{String, Any}("mode" => "explicit", "values" => [1.0, 3.0]),
        "algorithm" => merge(Dict{String, Any}("search" => "segment_tree"), algorithm),
        "output" => merge(
            Dict{String, Any}("root" => joinpath(dir, name), "format" => "csv"), output))
    isempty(limits) || (cfg["limits"] = Dict{String, Any}(limits))
    path = joinpath(dir, name * ".toml")
    open(io -> TOML.print(io, cfg), path, "w")
    return path
end

"the exception thrown by `f()`, `nothing` when it returns"
function thrown_by(f)
    try
        f()
    catch err
        return err
    end
    return nothing
end

"the session record of a generation run"
session_record(h) = TOML.parsefile(joinpath(h.dir, "sessions", h.session * ".toml"))

@testset "Contract paths" begin
    @testset "Schema-2 collection" begin
        c = load_collection(joinpath(FIXTURES, "schema2"))
        @test c.metadata["schema"] == "waitingtimes-provenance/2"
        @test c.time_axis === :elapsed && c.mode === :elapsed && c.digits == 0 &&
              c.time_unit === :sample && c.n_observations == 18 && c.n_gaps == 1
        @test thresholds(c) == [Threshold(1, 0), Threshold(3, 0)]
        @test WT.Storage.read_gap_file(joinpath(c.dir, "gaps.csv")) ==
              [(start = 9, stop = 11, kind = "unknown", source = "")]
        for δ in ("1", "3")
            @test WT.class_counts(c, δ) === nothing
            @test WT.censoring_histogram(c, δ) === nothing
        end
        s = load_series(c)
        @test length(s) == 18 && s.times == CONTRACT_TIMES && s.values == CONTRACT_VALUES
        @test eltype(s.values) == Int64 && s.epoch === nothing
        @test s.gaps == [(9, 11)] && s.gap_kinds == ["unknown"] && s.gap_sources == [""]
        @test gap_table(s) ==
              [(start = 9, stop = 11, length = 2, kind = "unknown", source = "")]
        @test WT.record_length(c) == WT.record_length(s) == 20
        @test WT.segment_lengths(c) == WT.segment_lengths(s) == [8, 10]
        @test WT.source_summary(c) === nothing && source_descriptor(c) === nothing
        # support, counts and (candidates, exact, gap-crossing, right-censored)
        expected = Dict("1" => ([1, 2, 3, 4], [7, 4, 4, 1], (17, 14, 2, 1)),
            "3" => ([1, 2, 3, 6, 8, 9], [4, 2, 1, 1, 2, 3], (17, 8, 5, 4)))
        for (δ, (sup, cnt, accounting)) in expected
            d = distribution(c, δ)
            k = parse(Int, δ)
            reference = empirical_distribution(waiting_times(s, k, NaiveSearch()),
                threshold(k, s), s)
            @test WT.support(d) == WT.support(reference) == sup
            @test WT.counts(d) == WT.counts(reference) == cnt
            @test (d.n_candidates, d.n_exact, d.n_gap_crossing, d.n_right_censored) ==
                  accounting
            @test d == reference
            @test WT.probabilities(d) ≈ cnt ./ sum(cnt)
            @test WT.cumulative(d) ≈ cumsum(cnt) ./ sum(cnt)
        end
    end

    @testset "Dense waiting-time files" begin
        mktempdir() do dir
            csv = contract_csv(dir)
            h = run_pipeline(contract_config(dir, csv, "dense";
                output = Dict{String, Any}("store_waiting_times" => true)))
            c = load_collection(h.dir)
            s = load_series(c)
            @test s.times == CONTRACT_TIMES && s.gaps == [(9, 11)] &&
                  s.gap_kinds == ["detected"]
            for δ in ("1", "3")
                path = joinpath(h.dir, "waiting_times", "delta=$δ.csv")
                @test isfile(path)
                table = WT.Storage.read_waiting_times(path)
                τ = waiting_times(s, parse_threshold(δ, 0), NaiveSearch())
                class = first(classify(τ, s))
                @test nrow(table) == 18
                @test table.tau == τ == CONTRACT_TAU[δ]
                @test table.class == class == CONTRACT_CLASS[δ]
            end
        end
    end

    @testset "Limit guards" begin
        mktempdir() do dir
            csv = contract_csv(dir)
            err = thrown_by(() -> run_pipeline(contract_config(dir, csv, "ram";
                limits = Dict{String, Any}("max_ram_gb" => 1e-9))))
            @test err isa ArgumentError && occursin("max_ram_gb", err.msg)
            err = thrown_by(() -> run_pipeline(contract_config(dir, csv, "cuda";
                algorithm = Dict{String, Any}("search" => "device", "backend" => "cuda"))))
            @test err isa ArgumentError && occursin("cuda", err.msg)
            # the reference kernel scans 64 elements at δ = 3, above the bound of 1
            h = run_pipeline(contract_config(dir, csv, "work";
                algorithm = Dict{String, Any}("reference_checks" => 1),
                limits = Dict{String, Any}("max_reference_work" => 1)))
            @test h.computed == ["1", "3"]
            check = only(session_record(h)["reference_checks"])
            @test check["delta"] == "3" && check["kernel"] == "naivesearch" &&
                  check["skipped"] === true && check["work"] == 64 &&
                  !haskey(check, "equal")
            @test only(h.reference_checks)["skipped"] === true
        end
    end

    @testset "Reference kernels" begin
        mktempdir() do dir
            csv = contract_csv(dir)
            for (kernel, name) in (("guarded", "guardedsearch"), ("device", "devicesearch"))
                h = run_pipeline(contract_config(dir, csv, kernel;
                    algorithm = Dict{String, Any}("reference_kernel" => kernel,
                        "backend" => "none", "reference_checks" => 2)))
                @test h.computed == ["1", "3"]
                checks = session_record(h)["reference_checks"]
                @test length(checks) == 2
                @test sort([r["delta"] for r in checks]) == ["1", "3"]
                @test all(
                    r -> r["kernel"] == name && r["equal"] === true &&
                         r["skipped"] === false, checks)
            end
        end
    end

    @testset "Gap absorption" begin
        # sample period 250: the detected gap [251, 1000) spans a hole and a session
        # closure; the hole extends back to its start, the session forward to its
        # stop, and the space between them goes to the hole
        detected = QuantizedSeries([1.0, 2.0, 3.0, 4.0], 0; times = [0, 250, 1000, 1250],
            cadence = 250)
        @test detected.gaps == [(251, 1000)] && detected.gap_kinds == ["detected"]
        absorbed = declare_gaps(detected,
            [(start = 300, stop = 500, kind = "hole", source = "holes.csv"),
                (start = 600, stop = 900, kind = "session", source = "calendar")])
        @test absorbed.gaps == [(251, 600), (600, 1000)]
        @test absorbed.gap_kinds == ["hole", "session"] &&
              absorbed.gap_sources == ["holes.csv", "calendar"]

        base = QuantizedSeries(Int32[1, 2], [1, 10], 0)
        overlapping = declare_gaps(base,
            [(start = 2, stop = 7, kind = "declared", source = "manual"),
                (start = 4, stop = 10, kind = "gap", source = "masks/gaps.csv")])
        @test overlapping.gaps == [(2, 10)] && overlapping.gap_kinds == ["gap+declared"] &&
              overlapping.gap_sources == ["manual;masks/gaps.csv"]
        same = declare_gaps(base, [(2, 5), (5, 10)]; kind = "hole", source = "holes.csv")
        @test same.gaps == [(2, 10)] && same.gap_kinds == ["hole"] &&
              same.gap_sources == ["holes.csv"]
        different = declare_gaps(base,
            [(start = 2, stop = 5, kind = "gap", source = "masks/gaps.csv"),
                (start = 5, stop = 10, kind = "hole", source = "holes.csv")])
        @test different.gaps == [(2, 5), (5, 10)] &&
              different.gap_kinds == ["gap", "hole"] &&
              different.gap_sources == ["masks/gaps.csv", "holes.csv"]
    end
end
