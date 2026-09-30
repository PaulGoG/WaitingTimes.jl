# Prepare a series from a configuration without generating distributions:
# prints sampling and value diagnostics, the gap table, and an in-terminal
# overview, so large gaps can be located and cut before a run. With
# --digits-scan it also prints the sensitivity of the δ = 0 distribution to
# the number of decimals (digits_sensitivity), the basis of digits = "auto".
#
#   julia scripts/prepare.jl --config PATH [--top N] [--digits-scan]
include(joinpath(dirname(@__DIR__), "activate.jl"))

using WaitingTimes
using WaitingTimes.Preprocessing: digits_sensitivity, resolution_digits, sampling_summary,
                                  terminal_overview, value_summary

function parse_commandline(argv)
    options = Dict("config" => joinpath(dirname(@__DIR__), "configs", "quickstart.toml"),
        "top" => "10", "digits-scan" => "false")
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg in ("--config", "--top") && i < length(argv)
            options[arg[3:end]] = argv[i + 1]
            i += 2
        elseif arg == "--digits-scan"
            options["digits-scan"] = "true"
            i += 1
        else
            error("usage: prepare.jl --config PATH [--top N] [--digits-scan]")
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
println("digits   ", series.digits,
    settings.digits === nothing ? " (auto)" : " (configured)", "; recorded resolution ",
    resolution === nothing ? "not on a decimal grid" : string(resolution, " decimals"))
if args["digits-scan"] == "true"
    println("sensitivity of the δ = 0 distribution to digits (ks: distance to digits + 1):")
    show(stdout, MIME("text/plain"),
        digits_sensitivity(ids.raw; digits = 0:settings.auto_max_digits);
        allrows = true, summary = false, eltypes = false)
    println()
end
table = gap_table(series)
println("gaps     ", length(table), " (longest first, top ", args["top"], "):")
for row in first(table, parse(Int, args["top"]))
    println(
        "  [", row.start, ", ", row.stop, ")  length ", row.length, " ", series.time_unit)
end
terminal_overview(ids.raw)
