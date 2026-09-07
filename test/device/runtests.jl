# Opt-in device tests on the local Intel GPU through oneAPI (skipped, with a
# message, when no functional device is present):
#
#   julia --threads=auto --project=test/device test/device/runtests.jl [N ...]
#
# Every threshold is checked bit for bit against the naive oracle, and the
# streaming and segment-tree kernels, on synthetic random walks of the given
# sizes (default 10^5 and 10^6) and on a walk with missing runs.
using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)

using Test
using StableRNGs: StableRNG
using WaitingTimes
using WaitingTimes.Synthetic: insert_missing, random_walk
using WaitingTimes.Backends: backend_name, device_fingerprint
using oneAPI

if !oneAPI.functional()
    println("oneAPI is not functional on this machine; device tests skipped")
    exit(0)
end

sizes = isempty(ARGS) ? [100_000, 1_000_000] : [round(Int, parse(Float64, a)) for a in ARGS]
alg = device_search(:oneapi)
println("backend: ", backend_name(alg.backend))
print(device_fingerprint(alg.backend))

@testset "oneAPI device kernel equals the oracle" begin
    rng = StableRNG(2026)
    for N in sizes
        for (label, x) in (("random walk", random_walk(rng, N)),
            ("walk with missing runs", insert_missing(rng, random_walk(rng, N), N ÷ 100)))
            s = QuantizedSeries(x, 2)
            ws = WaitingTimes.workspace(alg, s)
            ws_tree = WaitingTimes.workspace(SegmentTreeSearch(), s)
            for δ in (0.0, 0.5, 5.0, 50.0)
                thr = threshold(δ, s)
                τ_tree = waiting_times(s, thr, SegmentTreeSearch(); workspace = ws_tree)
                seconds = @elapsed τ_dev = waiting_times(s, thr, alg; workspace = ws)
                @test τ_dev == τ_tree
                if N <= 1_000_000
                    @test τ_dev == waiting_times(s, thr, NaiveSearch())
                end
                println(rpad(label, 24), " N = ", lpad(N, 8), "  δ = ", lpad(δ, 5),
                    "  device ", round(seconds; digits = 3), " s  equal ", τ_dev == τ_tree)
            end
        end
    end
end
