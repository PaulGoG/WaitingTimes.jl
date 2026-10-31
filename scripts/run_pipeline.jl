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

settings = load_settings(config_path; output_dir = args["output-dir"])

# Load KernelAbstractions and the GPU package named by [algorithm].backend when
# the configuration uses the device kernel; the package extensions then
# register the backends.
if settings.search === :device || settings.reference_kernel === :device
    WaitingTimes.Backends.load_device_packages(settings.backend)
end

handle = generate(settings)
println("collection ", handle.id, " at ", handle.dir)
println(
    "session ", handle.session, ": ", length(handle.computed), " thresholds computed, ",
    length(handle.skipped), " skipped, ", length(handle.reference_checks), " reference checks")
