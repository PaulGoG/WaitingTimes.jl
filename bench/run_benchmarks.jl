# Kernel benchmarks on synthetic random walks.
#
#   julia --threads=auto bench/run_benchmarks.jl [--sizes 1e4,1e5,1e6,4e6] [--csv PATH]
#                                                [--naive-work-limit 2e10]
#
# Sizes default to 10^4, 10^5, 10^6 and 4×10^6; each size is run in the small
# (δ = 0.5), medium (δ = 5) and large (δ = 50) threshold regimes. Every kernel is
# timed as the minimum over Chairmarks samples within a two-second budget, with
# the allocation count of that sample; workspace builds are timed separately and
# excluded. After the three regimes, the fenwick_all row times one multi-threshold
# Fenwick sweep over all three thresholds. The naive kernel runs only where its
# unguarded scan work (scan_work, in element comparisons) is at most
# --naive-work-limit, and is reported as skipped otherwise. --sizes takes a
# comma-separated list, --csv writes the rows to a CSV file. Every result is
# compared exactly with the segment-tree result, and any disagreement fails the run.
include(joinpath(@__DIR__, "activate.jl"))

using Chairmarks: @be
using Printf: @printf, @sprintf
using StableRNGs: StableRNG
using WaitingTimes
using WaitingTimes.Synthetic: random_walk

function parse_arguments(argv)
    sizes = [10_000, 100_000, 1_000_000, 4_000_000]
    csv = nothing
    naive_work_limit = 2e10
    i = 1
    while i <= length(argv)
        if argv[i] == "--sizes" && i < length(argv)
            sizes = [round(Int, parse(Float64, s)) for s in split(argv[i + 1], ",")]
            i += 2
        elseif argv[i] == "--csv" && i < length(argv)
            csv = argv[i + 1]
            i += 2
        elseif argv[i] == "--naive-work-limit" && i < length(argv)
            naive_work_limit = parse(Float64, argv[i + 1])
            i += 2
        else
            error("unknown argument $(argv[i])")
        end
    end
    return sizes, csv, naive_work_limit
end

const DIGITS = 2
const REGIMES = (("small", 0.5), ("medium", 5.0), ("large", 50.0))

function time_kernel(f; seconds = 2.0)
    b = @be f() seconds = seconds
    m = minimum(b)
    return (seconds = m.time, allocations = m.allocs, samples = length(b.samples))
end

function record_row!(rows, N, regime, δ, name, timing, build, mean_τ, censored, equal)
    push!(rows,
        (N = N, regime = regime, delta = δ, kernel = name, seconds = timing.seconds,
            allocations = timing.allocations, samples = timing.samples, build = build,
            mean_tau = mean_τ, censored = censored, equal = equal))
    @printf("%-9d %-7s δ=%-6.1f %-13s %10.4f s  allocs %8d  samples %5d  build %8.4f s  mean τ %10.1f  censored %.4f  equal %s\n",
        N, regime, δ, name, timing.seconds, timing.allocations, timing.samples, build,
        mean_τ, censored, equal)
    return rows
end

function benchmark_size(N, rows, naive_work_limit)
    rng = StableRNG(20260907)
    s = QuantizedSeries(random_walk(rng, N), DIGITS)
    build = Dict(
        "guarded" => @elapsed(WaitingTimes.workspace(GuardedSearch(), s)),
        "segment_tree" => @elapsed(WaitingTimes.workspace(SegmentTreeSearch(), s)),
        "fenwick" => @elapsed(WaitingTimes.workspace(FenwickSweep(), s))
    )
    ws = Dict(name => WaitingTimes.workspace(alg, s)
    for (name, alg) in ("guarded" => GuardedSearch(), "segment_tree" =>
        SegmentTreeSearch(),
        "fenwick" => FenwickSweep()))
    τ_trees = Vector{Any}()
    for (regime, δ) in REGIMES
        thr = threshold(δ, s)
        τ_tree = waiting_times(s, thr, SegmentTreeSearch(); workspace = ws["segment_tree"])
        push!(τ_trees, τ_tree)
        mean_τ = count(>(0), τ_tree) == 0 ? NaN : sum(τ_tree) / count(>(0), τ_tree)
        censored = count(==(0), τ_tree[1:(end - 1)]) / (N - 1)
        kernels = Any[
            ("segment_tree",
                () -> waiting_times(s, thr, SegmentTreeSearch(); workspace = ws["segment_tree"])),
            ("fenwick",
                () -> waiting_times(s, thr, FenwickSweep(); workspace = ws["fenwick"])),
            ("streaming", () -> waiting_times(s, thr, StreamingSearch())),
            ("guarded",
                () -> waiting_times(s, thr, GuardedSearch(); workspace = ws["guarded"]))
        ]
        work = WaitingTimes.scan_work(τ_tree, s)
        if work <= naive_work_limit
            push!(kernels, ("naive", () -> waiting_times(s, thr, NaiveSearch())))
        else
            @printf("naive skipped at N = %d, δ = %.1f: scan work %.3e exceeds the limit %.3e\n",
                N, δ, work, naive_work_limit)
        end
        for (name, f) in kernels
            timing = time_kernel(f)
            equal = f() == τ_tree
            record_row!(rows, N, regime, δ, name, timing, get(build, name, 0.0), mean_τ,
                censored, equal)
        end
    end
    thrs = [threshold(δ, s) for (_, δ) in REGIMES]
    f_all = () -> waiting_times(s, thrs, FenwickSweep(); workspace = ws["fenwick"])
    timing = time_kernel(f_all)
    equal = f_all() == τ_trees
    record_row!(rows, N, "all", NaN, "fenwick_all", timing, build["fenwick"], NaN, NaN,
        equal)
    return rows
end

sizes, csv, naive_work_limit = parse_arguments(ARGS)
println("threads = ", Threads.nthreads(), ", digits = ", DIGITS)
rows = NamedTuple[]
for N in sizes
    benchmark_size(N, rows, naive_work_limit)
end
if csv !== nothing
    open(csv, "w") do io
        println(io,
            "N,regime,delta,kernel,seconds,allocations,samples,build_seconds,mean_tau,censored_fraction,equal")
        for r in rows
            println(io,
                join(
                    (r.N, r.regime, r.delta, r.kernel,
                        r.seconds, r.allocations, r.samples,
                        r.build, r.mean_tau, r.censored, r.equal),
                    ","))
        end
    end
    println("wrote ", csv)
end
all(r -> r.equal, rows) || error("kernel disagreement detected")
