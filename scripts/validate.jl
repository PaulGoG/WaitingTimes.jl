# Compare the configured kernel with the oracle on a configuration's series.
#
#   julia --threads=auto --project scripts/validate.jl --config PATH [--deltas 0.5,5,50]
include(joinpath(dirname(@__DIR__), "activate.jl"))

using WaitingTimes

function parse_commandline(argv)
    options = Dict("config" => joinpath(dirname(@__DIR__), "configs", "quickstart.toml"),
        "deltas" => nothing)
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg in ("--config", "--deltas") && i < length(argv)
            options[arg[3:end]] = argv[i + 1]
            i += 2
        else
            error("usage: validate.jl --config PATH [--deltas a,b,c]")
        end
    end
    return options
end

args = parse_commandline(ARGS)
settings = load_settings(abspath(args["config"]))
deltas = args["deltas"] === nothing ? nothing :
         [parse(Float64, s) for s in split(args["deltas"], ",")]
report = validate(settings; deltas = deltas)
println("kernel ", report["kernel"], " against oracle ",
    report["oracle"], " on ", report["series"])
for r in report["results"]
    println("  delta = ", r["delta"], "  equal = ", r["equal"], "  differences = ",
        r["n_differences"], "  oracle seconds = ", round(r["seconds"]; digits = 3))
end
println(report["all_equal"] ? "all thresholds agree" : "DISAGREEMENT DETECTED")
exit(report["all_equal"] ? 0 : 1)
