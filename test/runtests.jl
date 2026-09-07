using WaitingTimes
using Test
using Aqua
using ExplicitImports
using JET
using StableRNGs
using Statistics: mean

const WT = WaitingTimes
const FIXTURES = joinpath(@__DIR__, "fixtures")

# --- helpers -----------------------------------------------------------------

"Definition of the waiting time as a plain serial loop, independent of the kernels."
function reference_waiting_times(q::AbstractVector, t::AbstractVector, d::Integer)
    N = length(q)
    τ = zeros(eltype(t), N)
    for i in 1:(N - 1)
        for j in (i + 1):N
            if q[j] >= q[i] + d
                τ[i] = t[j] - t[i]
                break
            end
        end
    end
    return τ
end

"Next greater-or-equal element by monotonic stack: the O(N) oracle valid only for δ = 0."
function stack_waiting_times_zero(q::AbstractVector, t::AbstractVector)
    N = length(q)
    τ = zeros(eltype(t), N)
    stack = Int[]
    for j in 1:N
        while !isempty(stack) && q[j] >= q[stack[end]]
            i = pop!(stack)
            τ[i] = t[j] - t[i]
        end
        push!(stack, j)
    end
    return τ
end

"Space-delimited legacy table with a header line; returns columns as vectors of strings."
function read_legacy_table(path)
    lines = filter(!isempty, strip.(readlines(path)))
    header = split(lines[1])
    cols = [String[] for _ in header]
    for line in lines[2:end]
        for (k, field) in enumerate(split(line))
            push!(cols[k], field)
        end
    end
    return Dict(zip(header, cols))
end

random_walk(rng, N; digits = 2) = round.(cumsum(randn(rng, N)); digits = digits)

# --- suite -------------------------------------------------------------------

@testset "WaitingTimes.jl" begin
    @testset "Static QA" begin
        Aqua.test_all(WaitingTimes)
        @test ExplicitImports.check_no_implicit_imports(WaitingTimes) === nothing
        @test ExplicitImports.check_no_stale_explicit_imports(WaitingTimes) === nothing
        @test ExplicitImports.check_all_explicit_imports_via_owners(WaitingTimes) ===
              nothing
        @test ExplicitImports.check_all_qualified_accesses_via_owners(WaitingTimes) ===
              nothing
        JET.test_package(WaitingTimes; target_modules = (WaitingTimes,))
    end

    @testset "Quantisation and thresholds" begin
        x = [1.5074, -0.00005, 2.00005, 123.456789, 0.0]
        for digits in (0, 1, 2, 4)
            q = quantize(x, digits)
            @test q == round.(Int64, round.(x; digits = digits) .* 10^digits)
        end
        @test_throws ArgumentError quantize([1.0, NaN], 2)
        @test_throws ArgumentError quantize([1.0], 16)
        @test eltype(WT.narrow_integer(Int64[1, 2, -3])) == Int32
        @test eltype(WT.narrow_integer(Int64[2 ^ 31])) == Int64

        @test threshold(0.0005, 4) == Threshold(5, 4)
        @test threshold(25000, 0) == Threshold(25000, 0)
        @test threshold(0.1, 1) == Threshold(1, 1)
        @test_throws ArgumentError threshold(0.00055, 4)
        @test_throws ArgumentError threshold(-0.1, 1)
        @test format_threshold(5, 4) == "0.0005"
        @test format_threshold(25000, 0) == "25000"
        @test format_threshold(1000005, 2) == "10000.05"
        @test parse_threshold("0.0005", 4) == Threshold(5, 4)
        @test parse_threshold("32.5", 1) == Threshold(325, 1)
        @test parse_threshold("7", 2) == Threshold(700, 2)
        @test_throws ArgumentError parse_threshold("0.00055", 4)
        @test_throws ArgumentError parse_threshold("-1", 1)
        for (d, digits) in ((0, 0), (5, 4), (325, 1), (123456789, 3))
            δ = Threshold(d, digits)
            @test parse_threshold(format_threshold(δ), digits) == δ
        end
        @test float(Threshold(325, 1)) ≈ 32.5
        @test Threshold(1, 2) < Threshold(2, 2)
        @test_throws ArgumentError Threshold(1, 1) < Threshold(1, 2)
    end

    @testset "Series construction" begin
        s = QuantizedSeries([1.0, 2.0, 3.0], 1)
        @test s.values == Int32[10, 20, 30]
        @test s.times == [1, 2, 3]
        @test isempty(s.gaps)
        @test s.time_unit === :sample
        @test length(s) == 3 && WT.duration(s) == 2
        @test s.record.steps[1].op === :quantize

        # missing rows keep their time position; leading and trailing blocks are trimmed
        s = QuantizedSeries([missing, missing, 1.0, missing, 2.0, 3.0, missing], 0)
        @test s.times == [1, 3, 4]
        @test s.gaps == [(2, 3)]
        @test s.record.steps[1].summary["n_missing"] == 4

        # explicit irregular timestamps, no gap detection unless asked
        s = QuantizedSeries([1.0, 2.0, 3.0], 0; times = [10, 11, 100], time_unit = :nanosecond)
        @test isempty(s.gaps)
        s = QuantizedSeries([1.0, 2.0, 3.0], 0; times = [10, 11, 100], cadence = 5)
        @test s.gaps == [(12, 100)]

        @test_throws ArgumentError QuantizedSeries([1.0, 2.0], 0; times = [1, 1])
        @test_throws ArgumentError QuantizedSeries([1.0, 2.0], 0; times = [2, 1])
        @test_throws DimensionMismatch QuantizedSeries([1.0, 2.0], 0; times = [1])
        @test_throws ArgumentError QuantizedSeries([missing, missing], 0)
        @test_throws ArgumentError QuantizedSeries(Int32[1, 2], [1, 2], 0; time_unit = :fortnight)
        @test_throws ArgumentError QuantizedSeries(Int32[1, 2, 3], [1, 5, 9], 0; gaps = [(
            2, 6)])
        @test_throws ArgumentError QuantizedSeries(Int32[1, 2, 3], [1, 5, 9], 0; gaps = [(
            6, 5)])
        @test_throws ArgumentError QuantizedSeries(Int32[1, 2, 3], [1, 5, 9], 0; gaps = [
            (2, 4), (3, 5)])
        @test_throws ArgumentError QuantizedSeries(Int32[1, 2], [1, 5], 0; gaps = [(0, 1)])

        s = declare_gaps(QuantizedSeries(Int32[1, 2, 3], [1, 5, 9], 0), [
            (2, 3), (3, 5), (6, 9)])
        @test s.gaps == [(2, 5), (6, 9)]
        @test gap_table(s)[1] == (start = 2, stop = 5, length = 3)
    end

    @testset "Kernels on hand-computed series" begin
        # A = 1 3 2 5 4 4 6, sample index
        s = QuantizedSeries([1, 3, 2, 5, 4, 4, 6], 0)
        expected = Dict(
            0 => [1, 2, 1, 3, 1, 1, 0],
            1 => [1, 2, 1, 3, 2, 1, 0],
            2 => [1, 2, 1, 0, 2, 1, 0],
            3 => [3, 5, 1, 0, 0, 0, 0],
            5 => [6, 0, 0, 0, 0, 0, 0],
            6 => [0, 0, 0, 0, 0, 0, 0]
        )
        for (d, τ_expected) in expected, alg in (NaiveSearch(), GuardedSearch())

            @test waiting_times(s, d, alg) == τ_expected
        end
        @test waiting_times(s, "2") == expected[2]
        @test waiting_times(s, Threshold(2, 0)) == expected[2]
        @test_throws ArgumentError waiting_times(s, Threshold(2, 1))
        @test_throws DimensionMismatch waiting_times!(zeros(Int, 3), s, Threshold(1, 0), NaiveSearch())

        # time passes through missing samples (elapsed-time semantics)
        s = QuantizedSeries([1.0, missing, missing, 3.0, 2.0, 5.0], 0)
        @test s.times == [1, 4, 5, 6]
        @test waiting_times(s, 1) == [3, 2, 1, 0]
        @test waiting_times(s, 2) == [3, 2, 1, 0]

        # constant series: δ = 0 gives the sample spacing, δ > 0 censors everything
        s = QuantizedSeries(fill(2.5, 5), 1; times = [1, 2, 4, 8, 16])
        @test waiting_times(s, 0) == [1, 2, 4, 8, 0]
        @test waiting_times(s, 0.1) == zeros(Int, 5)

        # strictly increasing series with unit increments
        s = QuantizedSeries(collect(1:6), 0)
        @test waiting_times(s, 3) == [3, 3, 3, 0, 0, 0]

        # single observation: no candidates
        s = QuantizedSeries([1.0], 0)
        @test waiting_times(s, 0) == [0]

        # overflow guard on narrowed values
        s = QuantizedSeries(Int32[1, 2], [1, 2], 0)
        @test_throws OverflowError waiting_times(s, Threshold(typemax(Int32), 0))
    end

    @testset "Kernel equivalence and invariants (synthetic)" begin
        rng = StableRNG(20260907)
        for N in (10, 100, 1_000, 10_000), digits in (0, 2)

            x = random_walk(rng, N; digits = digits)
            s = QuantizedSeries(x, digits)
            ws = WT.workspace(GuardedSearch(), s)
            q, t = s.values, s.times
            deltas = [0, 1, 2, 5, 20, 1_000, 1_000_000] .* 10.0^-digits
            previous = nothing
            for δ in deltas
                thr = threshold(δ, s)
                τ_ref = reference_waiting_times(q, t, thr.d)
                τ_naive = waiting_times(s, thr, NaiveSearch(; chunk_size = 7))
                τ_guard = waiting_times(s, thr, GuardedSearch(); workspace = ws)
                @test τ_naive == τ_ref
                @test τ_guard == τ_ref
                if previous !== nothing
                    both = (previous .> 0) .& (τ_ref .> 0)
                    @test all(τ_ref[both] .>= previous[both])
                    @test count(==(0), τ_ref) >= count(==(0), previous)
                end
                previous = τ_ref
            end
            @test waiting_times(s, 0) == stack_waiting_times_zero(q, t)
        end

        # heavy ties: few distinct values
        x = rand(rng, 0:3, 5_000)
        s = QuantizedSeries(x, 0)
        for d in 0:4
            @test waiting_times(s, d, NaiveSearch()) ==
                  reference_waiting_times(s.values, s.times, d)
            @test waiting_times(s, d, GuardedSearch()) ==
                  reference_waiting_times(s.values, s.times, d)
        end

        # gaps never change a waiting time, only the classification
        x = Vector{Union{Missing, Float64}}(random_walk(rng, 2_000))
        x[rand(rng, 1:2_000, 150)] .= missing
        s = QuantizedSeries(x, 2)
        @test !isempty(s.gaps)
        plain = QuantizedSeries(s.values, s.times, s.digits)
        for δ in (0.0, 0.5, 5.0)
            τ = waiting_times(s, δ)
            @test τ == waiting_times(plain, δ)
            class, lower, upper = classify(τ, s)
            acc = class_counts(class)
            @test acc.n_candidates == length(s) - 1
            @test acc.n_exact + acc.n_gap_crossing + acc.n_right_censored ==
                  acc.n_candidates
            @test all(lower[1:(end - 1)] .<= upper[1:(end - 1)])
            @test all(upper[class .== WT.CLASS_EXACT] .== τ[class .== WT.CLASS_EXACT])
            @test all(lower[class .== WT.CLASS_EXACT] .== τ[class .== WT.CLASS_EXACT])
            @test all(τ[class .== WT.CLASS_RIGHT_CENSORED] .== 0)
        end
    end

    @testset "Classification on a hand-computed gapped series" begin
        # values at times 1 2 3 | gap [4, 7) | 7 8 ; A = 1 5 2 | 9 3
        s = QuantizedSeries([1.0, 5.0, 2.0, missing, missing, missing, 9.0, 3.0], 0)
        @test s.times == [1, 2, 3, 7, 8] && s.gaps == [(4, 7)]
        τ = waiting_times(s, 3)
        @test τ == [1, 5, 4, 0, 0]
        class, lower, upper = classify(τ, s)
        @test class == [WT.CLASS_EXACT, WT.CLASS_GAP_CROSSING, WT.CLASS_GAP_CROSSING,
            WT.CLASS_RIGHT_CENSORED, WT.CLASS_RIGHT_CENSORED]
        @test lower == [1, 1, 0, 1, 0]           # index 2: last observation before the gap is t = 3
        @test upper == [1, 5, 4, typemax(Int64), 0]
        @test class_counts(class) ==
              (n_candidates = 4, n_exact = 1, n_gap_crossing = 2, n_right_censored = 1)
        d_elapsed = empirical_distribution(τ, threshold(3, s), s)
        d_exact = empirical_distribution(τ, threshold(3, s), s; mode = :exact)
        @test WT.support(d_elapsed) == [1, 4, 5] && WT.counts(d_elapsed) == [1, 1, 1]
        @test WT.support(d_exact) == [1] && WT.counts(d_exact) == [1]
        @test d_elapsed.n_gap_crossing == 2 && d_exact.n_gap_crossing == 2
    end

    @testset "Empirical distribution" begin
        rng = StableRNG(7)
        s = QuantizedSeries(random_walk(rng, 5_000), 2)
        δ = threshold(1.0, s)
        τ = waiting_times(s, δ)
        d = empirical_distribution(τ, δ, s)
        @test issorted(WT.support(d)) && allunique(WT.support(d))
        @test sum(WT.counts(d)) == WT.nsamples(d) == count(>(0), τ[1:(end - 1)])
        @test sum(WT.probabilities(d)) ≈ 1.0
        @test WT.cumulative(d)[end] ≈ 1.0
        @test WT.survival(d) ≈ 1.0 .- WT.cumulative(d)
        @test mean(d) ≈ sum(τ[τ .> 0]) / count(>(0), τ)
        @test d.n_right_censored == count(==(0), τ[1:(end - 1)])
        @test d.n_gap_crossing == 0
        @test_throws ArgumentError empirical_distribution(τ, δ, s; mode = :other)
        @test occursin("WaitingTimeDistribution", sprint(show, d))
        @test occursin("QuantizedSeries", sprint(show, s))
        @test occursin("0.10", sprint(show, threshold(0.1, 2)))
        empty = empirical_distribution(zeros(Int64, length(s)), δ, s)
        @test WT.nsamples(empty) == 0 && isnan(mean(empty))
    end

    @testset "Legacy fixtures: EUR-USD daily closing rate" begin
        table = read_legacy_table(joinpath(FIXTURES, "fiatEURUSD.dat"))
        rate = parse.(Float64, table["Data"])
        s = QuantizedSeries(rate, 4)
        @test length(s) == 11572
        for text in ("0.0005", "0.005", "0.05", "0.5")
            legacy = read_legacy_table(joinpath(FIXTURES, "legacy",
                "WTS_ftEURUSD_clsng_raw_deltais$(text).dat"))
            δ = parse_threshold(text, 4)
            τ = waiting_times(s, δ)
            d = empirical_distribution(τ, δ, s)
            @test WT.support(d) == parse.(Int, legacy["time"])
            @test WT.probabilities(d) ≈ parse.(Float64, legacy["pdf"]) atol = 1e-12
            @test WT.cumulative(d) ≈ parse.(Float64, legacy["cdf"]) atol = 1e-12
            @test waiting_times(s, δ, NaiveSearch()) == τ
        end
    end
end
