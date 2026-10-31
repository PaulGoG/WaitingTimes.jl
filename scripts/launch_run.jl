# Launch scripts/run_pipeline.jl as a detached child process with the same
# Julia binary and all threads. Standard output and standard error go to one
# console log under data/logs/; beside it, run_<timestamp>.toml records the
# process identifier, the command, the log, the start time (UTC) and, with
# --config, the configuration path.
#
#   julia scripts/launch_run.jl [--config PATH] [--output-dir DIR]
include(joinpath(dirname(@__DIR__), "activate.jl"))

using Dates
using TOML

const PROJECT_ROOT = dirname(@__DIR__)
const PIPELINE_SCRIPT = joinpath(@__DIR__, "run_pipeline.jl")
const LOG_DIR = joinpath(PROJECT_ROOT, "data", "logs")
mkpath(LOG_DIR)

timestamp = Dates.format(now(), "yyyymmdd_HHMMSS")
console_log = joinpath(LOG_DIR, "run_$(timestamp).log")
record_path = joinpath(LOG_DIR, "run_$(timestamp).toml")

println("=" ^ 78)
println("  Launching WaitingTimes pipeline run (detached)")
println("=" ^ 78)
println("  project root : $PROJECT_ROOT")
println("  console log  : $console_log")

cmd = `$(Base.julia_cmd()) --threads=auto $PIPELINE_SCRIPT $ARGS`
io = open(console_log, "w")
process = run(detach(pipeline(cmd; stdout = io, stderr = io)); wait = false)
close(io)   # the child holds its own descriptor

record = Dict{String, Any}("pid" => getpid(process), "command" => join(cmd.exec, " "),
    "log" => console_log,
    "started" => Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS") * "Z")
config_index = findfirst(==("--config"), ARGS)
config_index === nothing || config_index == length(ARGS) ||
    (record["config"] = abspath(ARGS[config_index + 1]))
open(io -> TOML.print(io, record; sorted = true), record_path, "w")

println("  status       : RUNNING (PID $(getpid(process)))")
println("  job record   : $record_path")
println("  monitor with : tail -f $console_log")
println("=" ^ 78)
