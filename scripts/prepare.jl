# Prepare a series from a configuration without generating distributions:
# prints sampling and value diagnostics, the gap table, and an in-terminal
# overview, so large gaps can be located and cut before a run.
#
#   julia scripts/prepare.jl --config PATH [--top N]
include(joinpath(dirname(@__DIR__), "activate.jl"))

using WaitingTimes
using WaitingTimes.Preprocessing: resolution_digits, sampling_summary, terminal_overview,
                                  value_summary

function parse_commandline(argv)
    options = Dict("config" => joinpath(dirname(@__DIR__), "configs", "quickstart.toml"),
        "top" => "10")
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg in ("--config", "--top") && i < length(argv)
            options[arg[3:end]] = argv[i + 1]
            i += 2
        else
            error("usage: prepare.jl --config PATH [--top N]")
        end
    end
    return options
end

args = parse_commandline(ARGS)
settings = load_settings(abspath(args["config"]))
series, ids = prepare(settings)

println("dataset  ", ids.dataset_id)
println("series   ", ids.series_id)
println("series   ", series)
println("sampling ", sampling_summary(ids.raw))
println("values   ", value_summary(ids.raw))
resolution = resolution_digits(ids.raw)
println("digits   ", settings.digits, " configured; recorded resolution ",
    resolution === nothing ? "not on a decimal grid" : string(resolution, " decimals"))
table = gap_table(series)
println("gaps     ", length(table), " (longest first, top ", args["top"], "):")
for row in first(table, parse(Int, args["top"]))
    println(
        "  [", row.start, ", ", row.stop, ")  length ", row.length, " ", series.time_unit)
end
terminal_overview(ids.raw)
