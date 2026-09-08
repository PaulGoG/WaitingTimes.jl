# Exact point-by-point cross-validation of every kernel on a configured series.
#
#   julia --threads=auto --project=test/device scripts/crosscheck.jl --config PATH
#         [--every K] [--naive-every M] [--backend oneapi|cuda|amdgpu|metal|none] [--out PATH.csv]
#
# For every K-th threshold of the configured grid (default every one) the
# segment tree computes the reference vector τ_ref; every other kernel is run
# on the same threshold and compared index by index: number of differing
# indices, sum and maximum of |Δτ|, and whether the sorted multisets of the
# positive waiting times agree (the distribution-level comparison of the
# original analysis). The naive CPU oracle runs on every M-th checked
# threshold (default every one; raise it on million-point series). With
# --backend the device kernel runs on that GPU when its package is installed
# in the active environment. Rows go to the CSV; a summary is printed.
using WaitingTimes
using WaitingTimes.Backends: backend_name
using Printf: @printf

function parse_commandline(argv)
    options = Dict{String, Any}("config" => nothing, "every" => 1, "naive-every" => 1,
        "backend" => "none", "out" => nothing)
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg in ("--config", "--every", "--naive-every", "--backend", "--out") &&
           i < length(argv)
            key = arg[3:end]
            options[key] = key in ("every", "naive-every") ? parse(Int, argv[i + 1]) :
                           argv[i + 1]
            i += 2
        else
            error("usage: crosscheck.jl --config PATH [--every K] [--naive-every M] [--backend B] [--out PATH.csv]")
        end
    end
    options["config"] === nothing && error("--config is required")
    return options
end

const GPU_PACKAGES = Dict("cuda" => "CUDA", "amdgpu" => "AMDGPU", "metal" => "Metal",
    "oneapi" => "oneAPI")

args = parse_commandline(ARGS)
settings = load_settings(abspath(args["config"]))
series, ids = prepare(settings)
thresholds = threshold_list(settings, series)[1:args["every"]:end]
println(
    "series ", ids.series_id, ": ", length(series), " observations, ", length(thresholds),
    " thresholds checked")

kernels = Any[("guarded", GuardedSearch()), ("fenwick", FenwickSweep()),
    ("streaming", StreamingSearch()), ("device_cpu", DeviceSearch())]
backend = lowercase(String(args["backend"]))
if backend != "none"
    pkgname = GPU_PACKAGES[backend]
    if Base.find_package(pkgname) === nothing
        @warn "backend $backend requested but $pkgname is not installed in this environment"
    else
        Base.require(Main, Symbol(pkgname))
        alg = device_search(Symbol(backend))
        println("device backend: ", backend_name(alg.backend))
        push!(kernels, ("device_" * backend, alg))
    end
end
naive = NaiveSearch()

workspaces = Dict(name => WaitingTimes.workspace(alg, series) for (name, alg) in kernels)
ws_tree = WaitingTimes.workspace(SegmentTreeSearch(), series)
τ_ref = Vector{eltype(series.times)}(undef, length(series))
τ = similar(τ_ref)

out = args["out"] === nothing ? nothing : open(args["out"], "w")
out === nothing ||
    println(out, "dataset,delta,kernel,n,n_differ,sum_abs_diff,max_abs_diff,multiset_equal,seconds")
totals = Dict{String, Any}(name => (checked = 0, differing = 0, indices = 0, seconds = 0.0)
for name in vcat(first.(kernels), "naive"))

function record!(name, δ, τ_ref, τ, seconds)
    Δ = abs.(Int128.(τ) .- Int128.(τ_ref))
    n_differ = count(!=(0), Δ)
    sum_abs = sum(Δ)
    max_abs = maximum(Δ; init = zero(Int128))
    multiset = sort(filter(>(0), τ)) == sort(filter(>(0), τ_ref))
    t = totals[name]
    totals[name] = (checked = t.checked + 1, differing = t.differing + (n_differ > 0),
        indices = t.indices + n_differ, seconds = t.seconds + seconds)
    out === nothing || println(out,
        join(
            (ids.series_slug, format_threshold(δ), name,
                length(τ), n_differ, sum_abs, max_abs, multiset, seconds),
            ","))
    n_differ == 0 ||
        @printf("  DIFFERENCE %-12s δ = %s: %d indices, Σ|Δ| = %d, max |Δ| = %d, multiset equal %s\n",
            name, format_threshold(δ), n_differ, sum_abs, max_abs, multiset)
    return nothing
end

for (k, δ) in enumerate(thresholds)
    waiting_times!(τ_ref, series, δ, SegmentTreeSearch(); workspace = ws_tree)
    for (name, alg) in kernels
        seconds = @elapsed waiting_times!(τ, series, δ, alg; workspace = workspaces[name])
        record!(name, δ, τ_ref, τ, seconds)
    end
    if (k - 1) % args["naive-every"] == 0
        seconds = @elapsed waiting_times!(τ, series, δ, naive)
        record!("naive", δ, τ_ref, τ, seconds)
    end
    k % 50 == 0 && println("  ", k, " / ", length(thresholds), " thresholds")
end
out === nothing || close(out)

println("summary against the segment tree (", length(thresholds), " thresholds):")
for name in vcat(first.(kernels), "naive")
    t = totals[name]
    @printf("  %-12s checked %5d  thresholds with differences %3d  differing indices %6d  total %8.2f s\n",
        name, t.checked, t.differing, t.indices, t.seconds)
end
all(t -> t.differing == 0, values(totals)) || error("kernel disagreement detected")
println("all kernels agree index by index on every checked threshold")
