# Kernel benchmarks on synthetic random walks.
#
#   julia --threads=auto --project=bench bench/run_benchmarks.jl [--sizes 1e4,1e5,1e6,4e6] [--csv PATH]
#
# For every size and threshold regime the four batch kernels and the streaming
# replay are timed (wall time of one evaluation after a warm-up), the results
# are checked for exact equality, and a table is printed; with --csv the rows
# are also written to a CSV file. Sizes above 10^6 skip the naive oracle.
include(joinpath(@__DIR__, "activate.jl"))

using Printf: @printf, @sprintf
using StableRNGs: StableRNG
using WaitingTimes
using WaitingTimes.Synthetic: random_walk

function parse_arguments(argv)
    sizes = [10_000, 100_000, 1_000_000, 4_000_000]
    csv = nothing
    i = 1
    while i <= length(argv)
        if argv[i] == "--sizes" && i < length(argv)
            sizes = [round(Int, parse(Float64, s)) for s in split(argv[i + 1], ",")]
            i += 2
        elseif argv[i] == "--csv" && i < length(argv)
            csv = argv[i + 1]
            i += 2
        else
            error("unknown argument $(argv[i])")
        end
    end
    return sizes, csv
end

const DIGITS = 2
const REGIMES = (("small", 0.5), ("medium", 5.0), ("large", 50.0))

function time_kernel(f)
    f()
    return @elapsed f()
end

function benchmark_size(N, rows)
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
    for (regime, δ) in REGIMES
        thr = threshold(δ, s)
        τ_ref = waiting_times(s, thr, SegmentTreeSearch(); workspace = ws["segment_tree"])
        mean_τ = count(>(0), τ_ref) == 0 ? NaN : sum(τ_ref) / count(>(0), τ_ref)
        censored = count(==(0), τ_ref[1:(end - 1)]) / (N - 1)
        kernels = Any[
            ("segment_tree",
                () -> waiting_times(s, thr, SegmentTreeSearch(); workspace = ws["segment_tree"])),
            ("fenwick",
                () -> waiting_times(s, thr, FenwickSweep(); workspace = ws["fenwick"])),
            ("streaming", () -> waiting_times(s, thr, StreamingSearch())),
            ("guarded",
                () -> waiting_times(s, thr, GuardedSearch(); workspace = ws["guarded"]))
        ]
        N <= 1_000_000 &&
            push!(kernels, ("naive", () -> waiting_times(s, thr, NaiveSearch())))
        for (name, f) in kernels
            seconds = time_kernel(f)
            equal = f() == τ_ref
            push!(rows,
                (N = N, regime = regime, delta = δ, kernel = name, seconds = seconds,
                    build = get(build, name, 0.0), mean_tau = mean_τ, censored = censored,
                    equal = equal))
            @printf("%-9d %-7s δ=%-6.1f %-13s %10.4f s  build %8.4f s  mean τ %10.1f  censored %.4f  equal %s\n",
                N, regime, δ, name, seconds, get(build, name, 0.0), mean_τ, censored, equal)
        end
    end
    return rows
end

sizes, csv = parse_arguments(ARGS)
println("threads = ", Threads.nthreads(), ", digits = ", DIGITS)
rows = NamedTuple[]
for N in sizes
    benchmark_size(N, rows)
end
if csv !== nothing
    open(csv, "w") do io
        println(io, "N,regime,delta,kernel,seconds,build_seconds,mean_tau,censored_fraction,equal")
        for r in rows
            println(io,
                join(
                    (r.N, r.regime, r.delta, r.kernel, r.seconds, r.build, r.mean_tau,
                        r.censored, r.equal),
                    ","))
        end
    end
    println("wrote ", csv)
end
all(r -> r.equal, rows) || error("kernel disagreement detected")
