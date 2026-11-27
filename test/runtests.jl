# Test suite of WaitingTimes.jl. Run as a script, `julia --threads=auto
# test/runtests.jl` activates the test environment itself; under `Pkg.test()`
# the sandbox is already active and Pkg is absent from its load path, so the
# activation is skipped.
Base.identify_package("Pkg") === nothing || include(joinpath(@__DIR__, "activate.jl"))

using WaitingTimes
using KernelAbstractions: KernelAbstractions
using Test
using Aqua
using ExplicitImports
using JET
# JET follows the compiler, so the package analysis runs on releases only: on
# a pre-release it is skipped (JET 0.13.2 crashed the 1.14 pre-release in
# jl_code_for_staged), and on a release it runs regardless, so an unsupported
# JET fails instead of passing silently, which is the signal to widen its
# compat bound.
const JET_ENABLED = isempty(VERSION.prerelease)
using StableRNGs
using Statistics: mean
using WaitingTimes.Synthetic: random_walk, iid_series, insert_missing, irregular_times

const WT = WaitingTimes
const FIXTURES = joinpath(@__DIR__, "fixtures")

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

"Next greater-or-equal element by monotonic stack: the O(N) solution valid only for δ = 0."
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

rounded_walk(rng, N; digits = 2) = round.(cumsum(randn(rng, N)); digits = digits)

@testset "WaitingTimes.jl" begin
    @testset "Static QA" begin
        Aqua.test_all(WaitingTimes)
        @test ExplicitImports.check_no_implicit_imports(WaitingTimes) === nothing
        @test ExplicitImports.check_no_stale_explicit_imports(WaitingTimes) === nothing
        @test ExplicitImports.check_all_explicit_imports_via_owners(WaitingTimes) ===
              nothing
        @test ExplicitImports.check_all_qualified_accesses_via_owners(WaitingTimes) ===
              nothing
        if JET_ENABLED
            JET.test_package(WaitingTimes; target_modules = (WaitingTimes,))
        else
            @test_skip "JET package analysis (not run on the pre-release Julia $(VERSION))"
        end
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
        # the narrowing limit itself, and a magnitude that abs cannot represent
        @test eltype(WT.narrow_integer(Int64[2 ^ 30 - 1, -(2 ^ 30 - 1)])) == Int32
        @test eltype(WT.narrow_integer(Int64[2 ^ 30])) == Int64
        @test eltype(WT.narrow_integer(Int64[-(2 ^ 30)])) == Int64
        @test WT.narrow_integer(Int64[typemin(Int64)]) == [typemin(Int64)]
        @test isempty(WT.narrow_integer(Int64[]))

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
        # a literal beyond the Int64 grid is refused, not wrapped around
        @test parse_threshold("9223372036854775807", 0).d == typemax(Int64)
        @test_throws ArgumentError parse_threshold("9223372036854775808", 0)
        @test_throws ArgumentError parse_threshold("20000", 15)
        @test_throws ArgumentError parse_threshold("9" ^ 40, 0)
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
        @test gap_table(s)[1] ==
              (start = 2, stop = 5, length = 3, kind = "declared", source = "")
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

        # scan work in index units: A = 1 3 2 5 4 4 6 at δ = 3 gives τ = 3 5 1 0 0 0 0,
        # positions 4, 7, 4 for the resolved indices and 7 - n for the censored ones
        s = QuantizedSeries([1, 3, 2, 5, 4, 4, 6], 0)
        τ = waiting_times(s, 3)
        @test WT.scan_work(τ, s) == (3 + 5 + 1) + (3 + 2 + 1)
        @test WT.scan_work(τ, s; guarded = true) == 3 + 5 + 1
        s_irregular = QuantizedSeries([1, 3, 2, 5, 4, 4, 6], 0;
            times = [10, 20, 30, 45, 60, 80, 100], time_unit = :second)
        @test WT.scan_work(waiting_times(s_irregular, 3), s_irregular) ==
              WT.scan_work(τ, s)
        @test_throws DimensionMismatch WT.scan_work(zeros(Int, 3), s)
    end

    @testset "Kernel equivalence and invariants (synthetic)" begin
        rng = StableRNG(20260907)
        for N in (10, 100, 1_000, 10_000), digits in (0, 2)

            x = rounded_walk(rng, N; digits = digits)
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
        x = Vector{Union{Missing, Float64}}(rounded_walk(rng, 2_000))
        x[rand(rng, 1:2_000, 150)] .= missing
        s = QuantizedSeries(x, 2)
        @test !isempty(s.gaps)
        plain = QuantizedSeries(s.values, s.times, s.digits)
        for δ in (0.0, 0.5, 5.0)
            τ = waiting_times(s, δ)
            @test τ == waiting_times(plain, δ)
            class, lower, upper = classify(τ, s)
            acc = class_totals(class)
            @test acc.n_candidates == length(s) - 1
            @test acc.n_exact + acc.n_gap_crossing + acc.n_right_censored ==
                  acc.n_candidates
            @test all(lower[1:(end - 1)] .<= upper[1:(end - 1)])
            @test all(upper[class .== WT.CLASS_EXACT] .== τ[class .== WT.CLASS_EXACT])
            @test all(lower[class .== WT.CLASS_EXACT] .== τ[class .== WT.CLASS_EXACT])
            @test all(τ[class .== WT.CLASS_RIGHT_CENSORED] .== 0)
        end
    end

    @testset "Exact first-passage laws" begin
        # Waiting time of the first sample of every sequence of a finite
        # ensemble, against closed-form counts. No kernel output enters the
        # expected values.
        first_wait(x, a) = Int(waiting_times(QuantizedSeries(x, 0), a, NaiveSearch())[1])
        unresolved(τ, k) = count(w -> w == 0 || w > k, τ)

        # Independent values on G levels: the wait of a start value v exceeds k
        # when the next k values all lie below v + a.
        G, L = 4, 6
        sequences = vec(collect.(Iterators.product(ntuple(_ -> 0:(G - 1), L)...)))
        for a in 0:G
            τ = [first_wait(x, a) for x in sequences]
            for k in 1:(L - 1)
                @test unresolved(τ, k) ==
                      sum(min(v + a, G)^k for v in 0:(G - 1)) * G^(L - 1 - k)
            end
        end

        # Simple random walk, all 2^K paths. Hitting-time theorem for a ≥ 1:
        # P(τ = k) = (a / k) P(S_k = a). At a = 0 the wait lasts while the walk
        # stays below its start: P(τ > k) = C(k - 1, ⌊(k - 1)/2⌋) 2^-k.
        K = 12
        walks = vec([vcat(0, cumsum(collect(steps)))
                     for steps in Iterators.product(ntuple(_ -> (-1, 1), K)...)])
        for a in 1:4
            τ = [first_wait(x, a) for x in walks]
            for k in a:K
                paths = iseven(k + a) ? a * binomial(k, (k + a) ÷ 2) ÷ k * 2^(K - k) : 0
                @test count(==(k), τ) == paths
            end
        end
        τ = [first_wait(x, 0) for x in walks]
        for k in 1:K
            @test unresolved(τ, k) == binomial(k - 1, (k - 1) ÷ 2) * 2^(K - k)
        end

        # Continuous symmetric steps at δ = 0 (Sparre Andersen):
        # P(τ > k) = C(2k, k) 4^-k for any such step law. One wait per
        # independent replica makes every indicator a Bernoulli variable,
        # asserted within 5 standard errors.
        rng = StableRNG(1954)
        R, K = 20_000, 32
        for steps in (n -> randn(rng, n), n -> rand(rng, n) .- 0.5)
            τ = [Int(waiting_times(QuantizedSeries(cumsum(steps(K + 1)), 9), 0,
                     NaiveSearch())[1]) for _ in 1:R]
            for k in (1, 2, 4, 8, 16, 32)
                p = Float64(binomial(big(2k), k) // big(4)^k)
                @test abs(unresolved(τ, k) / R - p) <= 5 * sqrt(p * (1 - p) / R)
            end
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
        @test class_totals(class) ==
              (n_candidates = 4, n_exact = 1, n_gap_crossing = 2, n_right_censored = 1)
        d_elapsed = empirical_distribution(τ, threshold(3, s), s)
        d_exact = empirical_distribution(τ, threshold(3, s), s; mode = :exact)
        @test WT.support(d_elapsed) == [1, 4, 5] && WT.counts(d_elapsed) == [1, 1, 1]
        @test WT.support(d_exact) == [1] && WT.counts(d_exact) == [1]
        @test d_elapsed.n_gap_crossing == 2 && d_exact.n_gap_crossing == 2
        # gaps that begin right after the first observation and end at the last:
        # times 1 | gap [2, 4) | 4 5 | gap [6, 7) | 7 ; A = 1 | 3 2 | 5
        ends = QuantizedSeries([1.0, missing, missing, 3.0, 2.0, missing, 5.0], 0)
        @test ends.times == [1, 4, 5, 7] && ends.gaps == [(2, 4), (6, 7)]
        τ_ends = waiting_times(ends, 1)
        @test τ_ends == [3, 3, 2, 0]
        class, lower, upper = classify(τ_ends, ends)
        @test class ==
              [WT.CLASS_GAP_CROSSING, WT.CLASS_GAP_CROSSING, WT.CLASS_GAP_CROSSING,
            WT.CLASS_RIGHT_CENSORED]
        @test lower == [0, 1, 0, 0] && upper == [3, 3, 2, 0]
        class, lower, upper = classify(waiting_times(ends, 10), ends)
        @test all(==(WT.CLASS_RIGHT_CENSORED), class) && lower == [0, 1, 0, 0]
        @test upper == [typemax(Int64), typemax(Int64), typemax(Int64), 0]
    end

    @testset "Empirical distribution" begin
        rng = StableRNG(7)
        s = QuantizedSeries(rounded_walk(rng, 5_000), 2)
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
        # the classes handed in take the waits a horizon censors, as documented, so
        # that censoring_counts counts them with the other right-censored indices
        class, lower, _ = classify(τ, s)
        cut = empirical_distribution(τ, δ, s, class; horizon = 10)
        @test cut.n_right_censored > d.n_right_censored
        @test sum(last(WT.censoring_counts(class, lower))) == cut.n_right_censored
        # censored: no target in the record (τ = 0) or a wait beyond the horizon
        @test cut.n_right_censored == count(t -> t == 0 || t > 10, τ[1:(end - 1)])
    end

    @testset "Fast kernels equal the reference kernel" begin
        rng = StableRNG(2026)
        families = [
            ("random walk", 2, N -> random_walk(rng, N), nothing),
            ("drifting walk with cycles and jumps", 2,
                N -> random_walk(
                    rng, N; drift = 0.01, trend = 0.001, periods = ((24, 3.0),),
                    noise = 0.2, jump_probability = 0.01, jump_scale = 20.0), nothing),
            ("heavy-tailed walk", 1, N -> random_walk(rng, N; tail_alpha = 1.5), nothing),
            ("iid normal", 2, N -> iid_series(rng, N), nothing),
            ("iid uniform", 3, N -> iid_series(rng, N; distribution = :uniform), nothing),
            ("few distinct values", 0, N -> Float64.(rand(rng, 0:3, N)), nothing),
            ("walk with missing runs", 2,
                N -> insert_missing(rng, random_walk(rng, N), N ÷ 50), nothing),
            ("walk on irregular times", 2, N -> random_walk(rng, N),
                N -> irregular_times(rng, N; mean_interval = 7.0))
        ]
        # N = 10^5 runs the first two families only, without the 10^7 threshold
        for N in (1_000, 10_000, 100_000),
            (name, digits, make, make_times) in (N == 100_000 ? families[1:2] : families)

            x = make(N)
            s = make_times === nothing ? QuantizedSeries(x, digits) :
                QuantizedSeries(x, digits; times = make_times(N), time_unit = :second)
            ws_guard = WT.workspace(GuardedSearch(), s)
            ws_tree = WT.workspace(SegmentTreeSearch(), s)
            ws_fenwick = WT.workspace(FenwickSweep(), s)
            ws_device = WT.workspace(DeviceSearch(), s)
            ks = N == 100_000 ? (0, 1, 3, 10, 100, 2_000) : (0, 1, 3, 10, 100, 2_000, 10^7)
            deltas = [threshold(k * 10.0^-digits, s) for k in ks]
            references = [waiting_times(s, δ, NaiveSearch()) for δ in deltas]
            @testset "$name, N = $N" begin
                for (δ, τ_ref) in zip(deltas, references)
                    @test waiting_times(s, δ, GuardedSearch(); workspace = ws_guard) ==
                          τ_ref
                    @test waiting_times(s, δ, SegmentTreeSearch(); workspace = ws_tree) ==
                          τ_ref
                    @test waiting_times(s, δ, FenwickSweep(); workspace = ws_fenwick) ==
                          τ_ref
                    @test waiting_times(s, δ, StreamingSearch()) == τ_ref
                    @test waiting_times(s, δ, DeviceSearch(); workspace = ws_device) ==
                          τ_ref
                end
                @test waiting_times(s, deltas, FenwickSweep(); workspace = ws_fenwick) ==
                      references
            end
        end
        # the smallest series and the ends of the Int32 range, every kernel; the
        # expected vectors follow from the definition by hand
        M = 2^30 - 1
        edge = QuantizedSeries(Float64[-M, 0, M], 0)
        negative = QuantizedSeries([-10.0, -5.0], 0)
        @test eltype(edge.values) == Int32 == eltype(negative.values)
        for alg in (NaiveSearch(), GuardedSearch(), SegmentTreeSearch(), FenwickSweep(),
            StreamingSearch(), DeviceSearch())
            @test waiting_times(QuantizedSeries([3.0], 0), 0, alg) == [0]
            @test waiting_times(QuantizedSeries([3.0, 3.0], 0), 0, alg) == [1, 0]
            @test waiting_times(QuantizedSeries([3.0, 3.0], 0), 1, alg) == [0, 0]
            @test waiting_times(QuantizedSeries([3.0, 2.0], 0), 0, alg) == [0, 0]
            @test waiting_times(edge, Threshold(M, 0), alg) == [1, 1, 0]
            @test waiting_times(edge, Threshold(M + 1, 0), alg) == [2, 0, 0]
            # q_n + d would leave Int32 at the largest value
            @test_throws OverflowError waiting_times(edge, Threshold(M + 2, 0), alg)
            # d itself leaves Int32 although the values are negative
            @test waiting_times(negative, Threshold(typemax(Int32), 0), alg) == [0, 0]
            @test_throws OverflowError waiting_times(
                negative, Threshold(Int64(typemax(Int32)) + 1, 0), alg)
        end
        s = QuantizedSeries([3.0, 3.0], 0)
        @test WT.first_at_least(WT.workspace(SegmentTreeSearch(), s), 3, Int32(0)) == 0
        @test_throws DimensionMismatch waiting_times!(
            [zeros(Int, 2)], s, [Threshold(0, 0), Threshold(1, 0)], FenwickSweep())
    end

    @testset "Streaming evaluation" begin
        rng = StableRNG(31)
        x = random_walk(rng, 3_000)
        s = QuantizedSeries(x, 2)
        q, t = s.values, s.times
        δ = threshold(0.5, s)
        state = StreamingState(s, δ)
        acc = DistributionAccumulator{Int64}()
        partial = zeros(Int64, length(s))
        checkpoints = (1, 2, 3, 50, 999, 3_000)
        for m in 1:length(s)
            resolved = WT.update!(state, t[m], q[m])
            for (n, τ_n) in resolved
                partial[n] = τ_n
                push!(acc, τ_n)
            end
            if m in checkpoints
                prefix = QuantizedSeries(q[1:m], t[1:m], 2)
                τ_prefix = waiting_times(prefix, δ, NaiveSearch())
                @test partial[1:m] == τ_prefix
                @test pending(state) == count(==(0), τ_prefix)
                @test state.n_seen == m
                d_stream = empirical_distribution(acc, state)
                d_batch = empirical_distribution(τ_prefix, δ, prefix)
                @test WT.support(d_stream) == WT.support(d_batch)
                @test WT.counts(d_stream) == WT.counts(d_batch)
                @test WT.probabilities(d_stream) ≈ WT.probabilities(d_batch)
                @test d_stream.n_candidates == d_batch.n_candidates
                @test d_stream.n_right_censored == d_batch.n_right_censored
                @test WT.nsamples(acc) == WT.nsamples(d_batch)
            end
        end
        @test partial == waiting_times(s, δ, NaiveSearch())
        # every prefix of a short record with missing runs, at three thresholds: after
        # m samples the state and the estimator hold the reference result on those m
        short = QuantizedSeries(
            insert_missing(StableRNG(32), random_walk(StableRNG(33), 300), 6), 1)
        grid = [0.0, 0.5, 4.0]
        online = OnlineWaitingTimes(grid, 1)
        states = [StreamingState(short, threshold(g, short)) for g in grid]
        seen = [zeros(Int64, length(short)) for _ in grid]
        waits_agree = Bool[]
        snapshots_agree = Bool[]
        for m in 1:length(short)
            push!(online, short.times[m], Float64(short.values[m]) / 10)
            prefix = QuantizedSeries(short.values[1:m], short.times[1:m], 1)
            for (k, g) in enumerate(grid)
                thr = threshold(g, short)
                for (n, τ_n) in WT.update!(states[k], short.times[m], short.values[m])
                    seen[k][n] = τ_n
                end
                τ_prefix = waiting_times(prefix, thr, NaiveSearch())
                push!(waits_agree, seen[k][1:m] == τ_prefix)
                push!(snapshots_agree,
                    snapshot(online)[k] == empirical_distribution(τ_prefix, thr, prefix))
            end
        end
        @test length(waits_agree) == 3 * length(short) && all(waits_agree)
        @test all(snapshots_agree)
        # accumulator form of update!, argument checks, overflow guard of a narrow state
        state2 = StreamingState(s, δ)
        acc2 = DistributionAccumulator{Int64}()
        total = sum(WT.update!(acc2, state2, t[m], q[m]) for m in 1:length(s))
        @test total == state.n_resolved == WT.nsamples(acc2)
        @test_throws ArgumentError WT.update!(state2, t[end], q[end])
        @test_throws ArgumentError push!(acc2, 0)
        @test_throws ArgumentError StreamingState{Int32, Int64}(Threshold(
            Int64(typemax(Int32)) + 1, 0))
        narrow = StreamingState{Int32, Int64}(Threshold(5, 0))
        @test_throws OverflowError WT.update!(narrow, 1, typemax(Int32))
        @test isempty(WT.update!(narrow, 1, Int32(1)))
        @test only(WT.update!(narrow, 2, Int32(6))) == (1, 1)
        # under a declared bound a target beyond the value type is unreachable, not an error
        capped = StreamingState{Int8, Int64}(Threshold(10, 0); upper_bound = 120)
        @test isempty(WT.update!(capped, 1, Int8(119)))
        @test capped.n_unreachable == 1 && pending(capped) == 0 && capped.n_seen == 1
        @test_throws OverflowError WT.update!(
            StreamingState{Int8, Int64}(Threshold(10, 0)), 1, Int8(119))
        # a narrow time type: a sample that would resolve a wait beyond typemax(Int32)
        # is refused before the state changes; a wait of exactly typemax(Int32) resolves
        clock = StreamingState{Int64, Int32}(Threshold(0, 0))
        @test isempty(WT.update!(clock, Int32(-2_000_000_000), 0))
        @test_throws OverflowError WT.update!(clock, Int32(2_000_000_000), 1)
        @test clock.n_seen == 1 && pending(clock) == 1 && clock.last_time == -2_000_000_000
        @test only(WT.update!(clock, Int32(147_483_647), 1)) == (1, typemax(Int32))
        # the stream itself may span more, as long as the waits it resolves fit
        @test isempty(WT.update!(clock, Int32(2_000_000_000), 0))
        @test WT.update!(clock, Int32(2_000_000_001), 1) == [(3, 1), (2, 1_852_516_354)]
        # under a horizon a wait beyond typemax(Int32) is evicted, also by compaction
        capped = StreamingState{Int64, Int32}(Threshold(0, 0); horizon = 10)
        WT.update!(capped, Int32(-2_000_000_000), 5)
        @test isempty(WT.update!(capped, Int32(2_000_000_000), 10)) && capped.n_evicted == 1
        capped = StreamingState{Int64, Int32}(Threshold(0, 0); horizon = 10)
        WT.update!(capped, Int32(-2_000_000_000), 5)
        @test isempty(WT.update!(capped, Int32(2_000_000_000), 0))
        @test pending(capped) == 1 && capped.n_evicted == 1
    end

    @testset "Online estimation at several thresholds" begin
        rng = StableRNG(41)
        x = random_walk(rng, 4_000)
        s = QuantizedSeries(x, 2)
        deltas = [0.0, 0.5, 5.0]
        est = OnlineWaitingTimes(deltas, 2)
        @test est.time_unit === :sample && length(est.thresholds) == 3
        resolved = sum(push!(est, v) for v in x)
        @test est.n_seen == length(x) && est.n_late == 0
        snaps = snapshot(est)
        for (δ, d_online) in zip(deltas, snaps)
            thr = threshold(δ, s)
            τ = waiting_times(s, thr, NaiveSearch())
            d_batch = empirical_distribution(τ, thr, s)
            @test WT.support(d_online) == WT.support(d_batch)
            @test WT.counts(d_online) == WT.counts(d_batch)
            @test WT.cumulative(d_online) ≈ WT.cumulative(d_batch)
            @test d_online.n_right_censored == d_batch.n_right_censored
            @test d_online.delta == Threshold(thr.d, 2)
        end
        @test resolved == sum(WT.nsamples(d) for d in snaps)
        # pending includes the latest sample, which is never a candidate
        @test pending(est) == [d.n_right_censored + 1 for d in snaps]
        st = status(est)
        @test length(st) == 3 && st[2].delta == "0.50" && st[2].pending == pending(est)[2]
        @test st[1].mean_waiting_time ≈ mean(snaps[1])
        @test occursin("3 thresholds", sprint(show, est))
        # explicit times, append!, and the late policy
        timed = OnlineWaitingTimes([0.5], 2; time_unit = :second, late_policy = :skip)
        t = irregular_times(rng, 500; mean_interval = 3.0)
        append!(timed, t, x[1:500])
        @test timed.n_seen == 500 && timed.n_late == 0
        @test push!(timed, t[end], 1.0) == 0 && timed.n_late == 1
        s_timed = QuantizedSeries(x[1:500], 2; times = t, time_unit = :second)
        d_timed = snapshot(timed)[1]
        @test WT.support(d_timed) == WT.support(empirical_distribution(
            waiting_times(s_timed, 0.5), threshold(0.5, s_timed), s_timed))
        @test d_timed.time_unit === :second
        strict = OnlineWaitingTimes([0.5], 2; time_unit = :second)
        push!(strict, 10, 1.0)
        @test_throws ArgumentError push!(strict, 10, 2.0)
        @test_throws ArgumentError push!(strict, 3.0)
        @test_throws ArgumentError OnlineWaitingTimes(Float64[], 2)
        @test_throws ArgumentError OnlineWaitingTimes([0.5, 0.5], 2)
        @test_throws ArgumentError OnlineWaitingTimes([0.5], 2; late_policy = :drop)
        @test_throws ArgumentError OnlineWaitingTimes([0.5], 2; time_unit = :fortnight)
        @test_throws ArgumentError push!(OnlineWaitingTimes([1.0], 0), NaN)
        @test_throws OverflowError push!(OnlineWaitingTimes([1.0], 0; value_type = Int8), 1000.0)
        # a sample whose target overflows at one threshold is refused before any state is fed
        tiny = OnlineWaitingTimes([1.0, 10.0], 0; value_type = Int8)
        @test_throws OverflowError push!(tiny, 120.0)
        @test tiny.n_seen == 0 && all(state -> state.n_seen == 0, tiny.states)
        @test push!(tiny, 100.0) == 0 && tiny.n_seen == 1 && pending(tiny) == [1, 1]
        # a wait beyond a narrow time type, or a time beyond it, is refused before any
        # state is fed, also when the wait fits at one threshold and not at another
        clock = OnlineWaitingTimes([0.0, 5.0], 0; time_type = Int32)
        @test push!(clock, -2_000_000_000, 0.0) == 0
        @test_throws OverflowError push!(clock, 2_000_000_000, 1.0)
        @test_throws InexactError push!(clock, 3_000_000_000, 1.0)
        @test clock.n_seen == 1 && pending(clock) == [1, 1]
        @test push!(clock, 147_483_647, 1.0) == 1
        @test WT.support(first(snapshot(clock))) == [typemax(Int32)]
        # the wait resolved at δ = 0 fits and the one at δ = 5 does not: neither state
        # takes the sample
        @test_throws OverflowError push!(clock, 2_000_000_000, 5.0)
        @test clock.n_seen == 2 && pending(clock) == [1, 2]
        @test all(state -> state.n_seen == 2, clock.states)
        @test WT.nsamples.(snapshot(clock)) == [1, 0]
        # under a horizon the stream spans more than typemax(Int32): every index
        # resolves one sample later, 10^6 time units on
        long = OnlineWaitingTimes([0.0], 0; time_type = Int32, horizon = 2_000_000)
        foreach(k -> push!(long, -2^31 + 1 + k * 10^6, k), 0:2200)
        @test WT.support(only(snapshot(long))) == [10^6]
        @test WT.counts(only(snapshot(long))) == [2200]
        @test_throws ArgumentError OnlineWaitingTimes([0.25], 1)
    end

    @testset "Distance between distributions" begin
        s = QuantizedSeries(random_walk(StableRNG(61), 5_000), 2)
        a = empirical_distribution(waiting_times(s, 0.5), threshold(0.5, s), s)
        b = empirical_distribution(waiting_times(s, 2.0), threshold(2.0, s), s)
        grid = sort!(union(WT.support(a), WT.support(b)))
        F(d, k) = (
            i = searchsortedlast(WT.support(d), k); i == 0 ? 0.0 : WT.cumulative(d)[i])
        @test WT.ks_distance(a, b) ≈ maximum(abs(F(a, k) - F(b, k)) for k in grid)
        @test WT.ks_distance(a, b) == WT.ks_distance(b, a) > 0
        @test WT.ks_distance(a, a) == 0
        empty = empirical_distribution(Int64[0], threshold(0, 0), QuantizedSeries([1.0], 0))
        @test isnan(WT.ks_distance(a, empty))
    end

    @testset "Bounded streaming memory" begin
        rng = StableRNG(53)
        # downward drift: a fixed fraction of the indices never resolves
        x = random_walk(rng, 20_000; drift = -0.5)
        s = QuantizedSeries(x, 2)
        q, t = s.values, s.times
        δ = threshold(0.5, s)
        τ = waiting_times(s, δ, NaiveSearch())
        H = 200
        free = StreamingState(s, δ)
        bounded = StreamingState(s, δ; horizon = H)
        acc = DistributionAccumulator{Int64}()
        partial = zeros(Int64, length(s))
        peak = 0
        for m in eachindex(q)
            WT.update!(free, t[m], q[m])
            WT.update!(bounded, t[m], q[m]) do n, τ_n
                partial[n] = τ_n
                push!(acc, τ_n)
            end
            peak = max(peak, length(bounded.pending))
        end
        @test partial == [τ_n <= H ? τ_n : 0 for τ_n in τ]
        @test pending(free) == count(==(0), τ) > 20 * H
        @test peak <= max(2 * (H + 1), WT.MIN_COMPACTION)
        @test pending(bounded) <= H + 1
        @test bounded.n_resolved + bounded.n_evicted + pending(bounded) == length(s)
        d_batch = empirical_distribution(τ, δ, s; horizon = H)
        @test empirical_distribution(acc, bounded) == d_batch
        @test d_batch.horizon == H && maximum(WT.support(d_batch)) <= H
        @test d_batch != empirical_distribution(τ, δ, s)
        @test occursin("horizon = 200", sprint(show, d_batch))
        @test_throws ArgumentError StreamingState(s, δ; horizon = 0)
        @test_throws ArgumentError empirical_distribution(τ, δ, s; horizon = 0)
        # a burst followed by sparse samples: the heap is bounded by twice the largest
        # number of samples that fell within one horizon, not by the current rate
        burst = StreamingState{Int64, Int64}(Threshold(100, 0); horizon = 1_000)
        arrivals = vcat(1:2_000, 4_000:2_000:50_000)
        window_peak = heap_peak = 0
        for (m, time) in enumerate(arrivals)
            WT.update!(burst, time, 0)
            window_peak = max(window_peak,
                count(u -> time - u <= 1_000, @view arrivals[1:m]))
            heap_peak = max(heap_peak, length(burst.pending))
        end
        @test window_peak == 1_001
        @test WT.MIN_COMPACTION < heap_peak <= 2 * window_peak
        @test pending(burst) == 1 && burst.n_evicted == length(arrivals) - 1
        # the horizon on an irregular clock equals the batch evaluation
        clock = irregular_times(StableRNG(54), 5_000; mean_interval = 7.0)
        si = QuantizedSeries(random_walk(StableRNG(55), 5_000; drift = -0.2), 2;
            times = clock, time_unit = :second)
        δi = threshold(0.5, si)
        timed = StreamingState(si, δi; horizon = 500)
        acc_i = DistributionAccumulator{Int64}()
        for m in eachindex(si.values)
            WT.update!(acc_i, timed, si.times[m], si.values[m])
        end
        d_timed = empirical_distribution(
            waiting_times(si, δi, NaiveSearch()), δi, si; horizon = 500)
        @test empirical_distribution(acc_i, timed; time_unit = :second) == d_timed
        @test 0 < d_timed.n_right_censored < length(si) - 1
        # bounded values: targets above the declared maximum never resolve
        u = iid_series(rng, 5_000; distribution = :uniform)
        su = QuantizedSeries(u, 2)
        δu = threshold(0.3, su)
        τu = waiting_times(su, δu, NaiveSearch())
        capped = StreamingState(su, δu; upper_bound = 100)
        acc_u = DistributionAccumulator{Int64}()
        for m in eachindex(su.values)
            WT.update!(acc_u, capped, su.times[m], su.values[m])
        end
        @test empirical_distribution(acc_u, capped) == empirical_distribution(τu, δu, su)
        @test capped.n_unreachable == count(>(100 - δu.d), su.values) > 0
        @test pending(capped) + capped.n_unreachable == count(==(0), τu)
        @test_throws ArgumentError WT.update!(capped, su.times[end] + 1, eltype(su.values)(101))
        # the estimator with both options equals the batch evaluation
        est = OnlineWaitingTimes([0.3, 0.6], 2; upper_bound = 1.0, horizon = 50)
        foreach(v -> push!(est, v), u)
        for (δr, d) in zip([0.3, 0.6], snapshot(est))
            thr = threshold(δr, su)
            @test d == empirical_distribution(waiting_times(su, thr), thr, su; horizon = 50)
        end
        @test all(r.resolved + r.evicted + r.unreachable + r.pending == length(u)
        for r in status(est))
        # a value above the bound is skipped as a missing observation
        spiky = copy(u)
        spiky[[100, 2_000]] .= 1.5
        skip = OnlineWaitingTimes([0.3], 2; upper_bound = 1.0, bound_policy = :skip)
        foreach(v -> push!(skip, v), spiky)
        @test skip.n_above_bound == 2 && skip.n_seen == length(u) - 2
        @test occursin("2 above bound", sprint(show, skip))
        holed = Union{Missing, Float64}[i in (100, 2_000) ? missing : v
                                        for (i, v) in enumerate(u)]
        sm = QuantizedSeries(holed, 2)
        thr = threshold(0.3, sm)
        d_skip = only(snapshot(skip))
        d_holed = empirical_distribution(waiting_times(sm, thr), thr, sm)
        @test WT.support(d_skip) == WT.support(d_holed) &&
              WT.counts(d_skip) == WT.counts(d_holed) &&
              d_skip.n_right_censored == d_holed.n_right_censored
        @test_throws ArgumentError push!(OnlineWaitingTimes([0.3], 2; upper_bound = 1.0), 1.5)
        @test_throws ArgumentError OnlineWaitingTimes([0.3], 2; bound_policy = :clip)
    end

    @testset "Device search selection" begin
        @test device_search(:none) isa DeviceSearch{<:KernelAbstractions.CPU}
        @test device_search(:auto) isa DeviceSearch{<:KernelAbstractions.CPU}
        @test WaitingTimes.Backends.host_backend(device_search(:none).backend)
        @test !WaitingTimes.Backends.host_backend(nothing)
        @test :KernelAbstractions in WaitingTimes.Backends.load_device_packages(:none)
        @test_throws ArgumentError WaitingTimes.Backends.load_device_packages(:tpu)
        @test_throws ArgumentError device_search(:cuda)
        @test WT.Backends.probe(Val(:cpu)) isa KernelAbstractions.CPU
        @test WT.Backends.probe(Val(:cuda)) === nothing
        @test WT.Backends.get_best_backend(; prefer = :none) isa KernelAbstractions.CPU
        @test WT.Backends.get_best_backend(; prefer = :auto) isa KernelAbstractions.CPU
        @test_throws ArgumentError WT.Backends.get_best_backend(; prefer = :cuda)
        @test_throws ArgumentError WT.Backends.get_best_backend(; prefer = :tpu)
        @test WT.Backends.GPU_PRIORITY == (:cuda, :amdgpu, :oneapi, :metal)
        s = QuantizedSeries([1.0, 3.0, 2.0, 5.0], 0)
        @test waiting_times(s, 2, DeviceSearch()) == [1, 2, 1, 0]
        @test_throws DimensionMismatch waiting_times!(zeros(Int, 2), s, Threshold(1, 0), DeviceSearch())
    end

    @testset "Synthetic generators" begin
        @test random_walk(StableRNG(1), 100) == random_walk(StableRNG(1), 100)
        @test length(random_walk(StableRNG(1), 10; periods = ((5, 1.0),), tail_alpha = 2.0)) ==
              10
        @test_throws ArgumentError random_walk(StableRNG(1), 0)
        @test_throws ArgumentError random_walk(StableRNG(1), 5; tail_alpha = 0.0)
        @test_throws ArgumentError random_walk(StableRNG(1), 5; jump_probability = 2.0)
        @test length(iid_series(StableRNG(1), 7; distribution = :exponential)) == 7
        @test_throws ArgumentError iid_series(StableRNG(1), 7; distribution = :cauchy)
        y = insert_missing(StableRNG(1), ones(100), 5; max_length = 3)
        @test any(ismissing, y) && count(ismissing, y) <= 15
        @test_throws ArgumentError insert_missing(StableRNG(1), ones(10), -1)
        ts = irregular_times(StableRNG(1), 500; mean_interval = 3.0)
        @test issorted(ts) && allunique(ts) && ts[1] == 1
        @test_throws ArgumentError irregular_times(StableRNG(1), 5; mean_interval = 0.5)
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

    include("pipeline_tests.jl")
    include("identity_tests.jl")
    include("structure_tests.jl")
    include("preprocessing_tests.jl")
    include("contract_tests.jl")
end
