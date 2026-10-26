# Generate (or extend) a collection of waiting-time distributions.
#
#   julia --threads=auto scripts/run_pipeline.jl [--config PATH] [--output-dir DIR]
#
# --config PATH      TOML configuration (default configs/quickstart.toml); relative
#                    paths inside it resolve against its own directory
# --output-dir DIR   output root overriding [output].root
include(joinpath(dirname(@__DIR__), "activate.jl"))

using WaitingTimes

const PROJECT_ROOT = dirname(@__DIR__)
const USAGE = """
WaitingTimes pipeline

    julia --threads=auto scripts/run_pipeline.jl [--config PATH] [--output-dir DIR]
"""

function parse_commandline(argv)
    options = Dict("config" => joinpath(PROJECT_ROOT, "configs", "quickstart.toml"),
        "output-dir" => nothing)
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg in ("-h", "--help")
            print(USAGE)
            exit(0)
        elseif arg in ("--config", "--output-dir")
            i < length(argv) || error("$arg requires a value\n$USAGE")
            options[arg[3:end]] = argv[i + 1]
            i += 2
        else
            error("Unknown argument '$arg'\n$USAGE")
        end
    end
    return options
end

args = parse_commandline(ARGS)
config_path = abspath(args["config"])
isfile(config_path) || error("Configuration file not found: $config_path")

# Load KernelAbstractions and the GPU package named by [algorithm].backend when
# the configuration uses the device kernel; the package extensions then
# register the backends.
let alg = get(effective_config(config_path), "algorithm", Dict{String, Any}())
    uses_device = get(alg, "search", "") == "device" ||
                  get(alg, "reference_kernel", "") == "device"
    uses_device && WaitingTimes.Backends.load_device_packages(
        Symbol(lowercase(String(get(alg, "backend", "none")))))
end

handle = run_pipeline(config_path; output_dir = args["output-dir"])
println("collection ", handle.id, " at ", handle.dir)
println(
    "session ", handle.session, ": ", length(handle.computed), " thresholds computed, ",
    length(handle.skipped), " skipped, ", length(handle.reference_checks), " reference checks")
