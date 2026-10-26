# Exact index-by-index comparison of every kernel with the reference kernel
# on the threshold grid of a configuration.
#
#   julia --threads=auto scripts/crosscheck.jl --config PATH [--every K]
#         [--reference-every M] [--backend oneapi|cuda|amdgpu|metal|none]
#         [--env DIR] [--out PATH.csv]
#
# Every K-th threshold of the grid is taken (default every one), and of these
# every M-th is checked (default every one). On a checked threshold every
# kernel is compared with the reference kernel of the configuration
# ([algorithm].reference_kernel) through `validate`: number of differing
# indices and the reference kernel's work and time; a comparison whose work
# exceeds [limits].max_reference_work is skipped. With --backend the device
# kernel also runs on that GPU; the environment must then contain the GPU
# package, which --env selects (test/device holds oneAPI). Rows go to the CSV;
# a summary is printed; a non-zero exit signals disagreement.
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

function main(options)
    # KernelAbstractions, when installed, enables the device kernel on the CPU;
    # --backend adds its GPU package
    backend = lowercase(String(options["backend"]))
    loaded = WaitingTimes.Backends.load_device_packages(Symbol(backend))

    settings = load_settings(abspath(options["config"]))
    series, ids = prepare(settings)
    deltas = threshold_list(settings, series)[1:options["every"]:end][1:options["reference-every"]:end]
    println(
        "series ", ids.series_id, ": ", length(series), " observations, ", length(deltas),
        " thresholds checked (every ", options["every"] * options["reference-every"],
        "th of the grid)")

    kernels = Pair{String, AbstractSearch}["guarded" => GuardedSearch(),
        "segment_tree" => SegmentTreeSearch(), "fenwick" => FenwickSweep(),
        "streaming" => StreamingSearch()]
    :KernelAbstractions in loaded && push!(kernels, "device_cpu" => DeviceSearch())
    if backend != "none"
        pkgname = WaitingTimes.Backends.GPU_PACKAGES[Symbol(backend)]
        Symbol(pkgname) in loaded ||
            error("backend $backend requires the package $pkgname in the environment $(options["env"])")
        alg = device_search(Symbol(backend))
        println("device backend: ", backend_name(alg.backend))
        push!(kernels, "device_" * backend => alg)
    end

    report = validate(settings; deltas = deltas, kernels = kernels)
    reference = report["reference_kernel"]
    println("reference kernel: ", reference)

    if options["out"] !== nothing
        open(options["out"], "w") do out
            println(out, "dataset,delta,base,kernel,n,n_differ,equal,skipped,work,seconds")
            for r in report["results"]
                println(out,
                    join(
                        (ids.series_slug, r["delta"], reference,
                            r["kernel"], length(series),
                            r["n_differences"], r["equal"], r["skipped"], r["work"],
                            r["seconds"]),
                        ","))
            end
        end
    end
    for r in report["results"]
        r["skipped"] || r["equal"] ||
            @printf("  DIFFERENCE %-12s against %s at δ = %s: %d indices\n",
                r["kernel"], reference, r["delta"], r["n_differences"])
    end

    println("summary (", length(deltas), " thresholds):")
    for k in report["kernels"]
        differing = count(r -> r["kernel"] == k["name"] && !r["skipped"] && !r["equal"],
            report["results"])
        @printf("  %-12s checked %5d  skipped %5d  thresholds with differences %3d  differing indices %6d  reference %8.2f s\n",
            k["name"], k["n_checked"], k["n_skipped"], differing, k["n_differences"],
            k["seconds"])
    end
    report["all_equal"] || error("kernel disagreement detected")
    println("all kernels agree index by index on every checked threshold")
    return nothing
end

main(OPTIONS)
