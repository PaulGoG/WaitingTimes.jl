# Test suite of WaitingTimes.jl; self-activating, so both
# `julia --threads=auto test/runtests.jl` and `Pkg.test()` run it.
include(joinpath(@__DIR__, "activate.jl"))

using WaitingTimes
using Test
using Aqua
using ExplicitImports
using JET
using StableRNGs
using Statistics: mean
using WaitingTimes.Synthetic: random_walk, iid_series, insert_missing, irregular_times,
                              duty_cycle_mask, bernoulli_mask, gilbert_elliott_mask,
                              stationary_loss_rate, Disruption, disruption_mask, apply_mask,
                              gap_scenario

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
        for N in (1_000, 10_000, 100_000), (name, digits, make, make_times) in families

            x = make(N)
            s = make_times === nothing ? QuantizedSeries(x, digits) :
                QuantizedSeries(x, digits; times = make_times(N), time_unit = :second)
            ws_guard = WT.workspace(GuardedSearch(), s)
            ws_tree = WT.workspace(SegmentTreeSearch(), s)
            ws_fenwick = WT.workspace(FenwickSweep(), s)
            ws_device = WT.workspace(DeviceSearch(), s)
            deltas = [threshold(k * 10.0^-digits, s)
                      for k in (0, 1, 3, 10, 100, 2_000, 10^7)]
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
        # segment tree on the smallest series
        s = QuantizedSeries([3.0], 0)
        @test waiting_times(s, 0, SegmentTreeSearch()) == [0]
        s = QuantizedSeries([3.0, 3.0], 0)
        @test waiting_times(s, 0, SegmentTreeSearch()) == [1, 0]
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
            resolved = update!(state, t[m], q[m])
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
        # accumulator-fed update and callback form
        state2 = StreamingState(s, δ)
        acc2 = DistributionAccumulator{Int64}()
        total = sum(update!(acc2, state2, t[m], q[m]) for m in 1:length(s))
        @test total == state.n_resolved == WT.nsamples(acc2)
        @test_throws ArgumentError update!(state2, t[end], q[end])
        @test_throws ArgumentError push!(acc2, 0)
        narrow = StreamingState{Int32, Int64}(Threshold(5, 0))
        @test_throws OverflowError update!(narrow, 1, typemax(Int32))
        @test isempty(update!(narrow, 1, Int32(1)))
        @test only(update!(narrow, 2, Int32(6))) == (1, 1)
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
            @test d_online.delta == Threshold{Int64}(thr.d, 2)
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
        @test_throws ArgumentError OnlineWaitingTimes([0.25], 1)
    end

    @testset "Device search selection" begin
        @test device_search(:none) isa DeviceSearch{<:WaitingTimes.Backends.CPU}
        @test device_search(:auto) isa DeviceSearch{<:WaitingTimes.Backends.CPU}
        @test_throws ArgumentError device_search(:cuda)
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

        # gap generators modelled on a duty-cycled telemetry link
        m = duty_cycle_mask(48; period = 24, on_fraction = 8 / 24)
        @test count(m) == 16 && m[1:8] == trues(8) && !any(m[9:24]) && m[25:32] == trues(8)
        @test duty_cycle_mask(10; period = 5, on_fraction = 0.4, phase = 1)[1:5] ==
              [true, false, false, false, true]
        @test_throws ArgumentError duty_cycle_mask(10; period = 0, on_fraction = 0.5)
        @test_throws ArgumentError duty_cycle_mask(10; period = 5, on_fraction = 1.5)
        b = bernoulli_mask(StableRNG(3), 200_000; p_loss = 0.1)
        @test isapprox(1 - count(b) / length(b), 0.1; atol = 0.005)
        @test all(bernoulli_mask(StableRNG(3), 10; p_loss = 0.0)) &&
              !any(bernoulli_mask(StableRNG(3), 10; p_loss = 1.0))
        @test_throws ArgumentError bernoulli_mask(StableRNG(3), 10; p_loss = 2.0)
        ge = (p_good_to_bad = 0.03, p_bad_to_good = 0.25,
            p_loss_good = 0.01, p_loss_bad = 0.5)
        g = gilbert_elliott_mask(StableRNG(4), 400_000; ge...)
        @test isapprox(1 - count(g) / length(g), stationary_loss_rate(; ge...); atol = 0.01)
        @test stationary_loss_rate(; p_good_to_bad = 0.0, p_bad_to_good = 0.0,
            p_loss_good = 0.2, p_loss_bad = 0.9) == 0.2
        @test_throws ArgumentError gilbert_elliott_mask(
            StableRNG(4), 10; p_good_to_bad = 1.5,
            p_bad_to_good = 0.5, p_loss_good = 0.0, p_loss_bad = 0.0)
        rate = stationary_loss_rate(; ge...)
        runs(mask) = (
            r = Int[]; len = 0; for v in mask
                if !v
                    len += 1
                elseif len > 0
                    push!(r, len)
                    len = 0
                end
            end; len > 0 && push!(r, len); r)
        @test maximum(runs(g)) >
              maximum(runs(bernoulli_mask(StableRNG(5), 400_000; p_loss = rate)))
        blackout = Disruption(101, 50, 20, 1.0)
        dm = disruption_mask(StableRNG(6), 300, [blackout])
        @test !any(dm[101:150]) && all(dm[1:100]) && all(dm[171:300])
        @test count(dm[151:170]) >= 1
        partial = Disruption(1, 100_000, 0, 0.3)
        pm = disruption_mask(StableRNG(7), 100_000, [partial])
        @test isapprox(1 - count(pm) / length(pm), 0.3; atol = 0.01)
        @test_throws ArgumentError Disruption(0, 10, 0, 0.5)
        @test_throws ArgumentError Disruption(1, 10, 0, 1.5)
        @test isequal(apply_mask([1.0, 2.0, 3.0], [true, false, true]), [1.0, missing, 3.0])
        @test_throws DimensionMismatch apply_mask([1.0, 2.0], [true])
        y, mask = gap_scenario(StableRNG(8), random_walk(StableRNG(8), 2_000); period = 24,
            on_fraction = 8 / 24, loss = :gilbert_elliott, ge..., disruptions = [Disruption(500, 100, 50, 1.0)])
        @test count(ismissing, y) == count(!, mask) && !any(mask[500:599])
        s_gap = QuantizedSeries(y, 2)
        @test length(s_gap.gaps) >= 80
        @test_throws ArgumentError gap_scenario(StableRNG(8), [1.0, 2.0]; loss = :cosmic)
        @test_throws ArgumentError gap_scenario(StableRNG(8), [1.0, 2.0]; loss = :bernoulli, p_loss = 1.0)
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
end
