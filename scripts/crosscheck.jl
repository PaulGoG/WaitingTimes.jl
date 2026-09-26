# Exact index-by-index comparison of every kernel with the naive reference
# kernel on the threshold grid of a configuration.
#
#   julia --threads=auto scripts/crosscheck.jl --config PATH [--every K]
#         [--reference-every M] [--backend oneapi|cuda|amdgpu|metal|none]
#         [--env DIR] [--out PATH.csv]
#
# Every K-th threshold of the grid is checked (default every one). The naive
# reference kernel is evaluated on every M-th checked threshold (default every
# one); on those thresholds every other kernel is compared with it index by
# index: number of differing indices, sum and maximum of |Δτ|, and equality of
# the sorted multisets of positive waiting times (the distribution-level
# comparison of the original analysis). On checked thresholds without a
# reference evaluation the segment tree stands in as the comparison base. With
# --backend the device kernel also runs on that GPU; the environment must then
# contain the GPU package, which --env selects (test/device holds oneAPI).
# Rows go to the CSV; a summary is printed; a non-zero exit signals
# disagreement.
function parse_commandline(argv)
    options = Dict{String, Any}("config" => nothing, "every" => 1, "reference-every" => 1,
        "backend" => "none", "env" => dirname(@__DIR__), "out" => nothing)
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg in
           ("--config", "--every", "--reference-every", "--backend", "--env", "--out") &&
           i < length(argv)
            key = arg[3:end]
            options[key] = key in ("every", "reference-every") ? parse(Int, argv[i + 1]) :
                           argv[i + 1]
            i += 2
        else
            error("usage: crosscheck.jl --config PATH [--every K] [--reference-every M] " *
                  "[--backend B] [--env DIR] [--out PATH.csv]")
        end
    end
    options["config"] === nothing && error("--config is required")
    return options
end

const OPTIONS = parse_commandline(ARGS)
include(joinpath(abspath(OPTIONS["env"]), "activate.jl"))

using WaitingTimes
using WaitingTimes.Backends: backend_name
using Printf: @printf

const GPU_PACKAGES = Dict("cuda" => "CUDA", "amdgpu" => "AMDGPU", "metal" => "Metal",
    "oneapi" => "oneAPI")

settings = load_settings(abspath(OPTIONS["config"]))
series, ids = prepare(settings)
thresholds = threshold_list(settings, series)[1:OPTIONS["every"]:end]
println(
    "series ", ids.series_id, ": ", length(series), " observations, ", length(thresholds),
    " thresholds checked, reference kernel on every ", OPTIONS["reference-every"], "th")

kernels = Any[("guarded", GuardedSearch()), ("segment_tree", SegmentTreeSearch()),
    ("fenwick", FenwickSweep()), ("streaming", StreamingSearch()),
    ("device_cpu", DeviceSearch())]
backend = lowercase(String(OPTIONS["backend"]))
if backend != "none"
    pkgname = GPU_PACKAGES[backend]
    Base.find_package(pkgname) === nothing &&
        error("backend $backend requires the package $pkgname in the environment $(OPTIONS["env"])")
    Base.require(Main, Symbol(pkgname))
    alg = device_search(Symbol(backend))
    println("device backend: ", backend_name(alg.backend))
    push!(kernels, ("device_" * backend, alg))
end

workspaces = Dict(name => WaitingTimes.workspace(alg, series) for (name, alg) in kernels)
τ_base = Vector{eltype(series.times)}(undef, length(series))
τ = similar(τ_base)

out = OPTIONS["out"] === nothing ? nothing : open(OPTIONS["out"], "w")
out === nothing || println(out,
    "dataset,delta,base,kernel,n,n_differ,sum_abs_diff,max_abs_diff,multiset_equal,seconds")
totals = Dict{String, Any}(name => (checked = 0, differing = 0, indices = 0, seconds = 0.0)
for name in first.(kernels))

function record!(name, base, δ, τ_base, τ, seconds)
    Δ = abs.(Int128.(τ) .- Int128.(τ_base))
    n_differ = count(!=(0), Δ)
    sum_abs = sum(Δ)
    max_abs = maximum(Δ; init = zero(Int128))
    multiset = n_differ == 0 || sort(filter(>(0), τ)) == sort(filter(>(0), τ_base))
    t = totals[name]
    totals[name] = (checked = t.checked + 1, differing = t.differing + (n_differ > 0),
        indices = t.indices + n_differ, seconds = t.seconds + seconds)
    out === nothing || println(out,
        join(
            (ids.series_slug, format_threshold(δ),
                base, name, length(τ), n_differ, sum_abs,
                max_abs, multiset, seconds),
            ","))
    n_differ == 0 ||
        @printf("  DIFFERENCE %-12s against %s at δ = %s: %d indices, Σ|Δ| = %d, max |Δ| = %d, multiset equal %s\n",
            name, base, format_threshold(δ), n_differ, sum_abs, max_abs, multiset)
    return nothing
end

for (k, δ) in enumerate(thresholds)
    reference = (k - 1) % OPTIONS["reference-every"] == 0
    base = reference ? "naive" : "segment_tree"
    if reference
        waiting_times!(τ_base, series, δ, NaiveSearch())
    else
        waiting_times!(τ_base, series, δ, SegmentTreeSearch();
            workspace = workspaces["segment_tree"])
    end
    for (name, alg) in kernels
        reference || name != "segment_tree" || continue
        seconds = @elapsed waiting_times!(τ, series, δ, alg; workspace = workspaces[name])
        record!(name, base, δ, τ_base, τ, seconds)
    end
    k % 50 == 0 && println("  ", k, " / ", length(thresholds), " thresholds")
end
out === nothing || close(out)

println("summary (", length(thresholds), " thresholds):")
for name in first.(kernels)
    t = totals[name]
    @printf("  %-12s checked %5d  thresholds with differences %3d  differing indices %6d  total %8.2f s\n",
        name, t.checked, t.differing, t.indices, t.seconds)
end
all(t -> t.differing == 0, values(totals)) || error("kernel disagreement detected")
println("all kernels agree index by index on every checked threshold")
