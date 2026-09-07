# Launch scripts/run_pipeline.jl as a detached child process with the same
# Julia binary, all threads, and a console log under data/logs/.
#
#   julia --project scripts/launch_run.jl [--config PATH] [--output-dir DIR]
include(joinpath(dirname(@__DIR__), "activate.jl"))

using Dates

const PROJECT_ROOT = dirname(@__DIR__)
const PIPELINE_SCRIPT = joinpath(@__DIR__, "run_pipeline.jl")
const LOG_DIR = joinpath(PROJECT_ROOT, "data", "logs")
mkpath(LOG_DIR)

timestamp = Dates.format(now(), "yyyymmdd_HHMMSS")
console_log = joinpath(LOG_DIR, "run_$(timestamp).log")

println("=" ^ 78)
println("  Launching WaitingTimes pipeline run (detached)")
println("=" ^ 78)
println("  project root : $PROJECT_ROOT")
println("  console log  : $console_log")

cmd = `$(Base.julia_cmd()) --project=$PROJECT_ROOT --threads=auto $PIPELINE_SCRIPT $ARGS`
process = run(pipeline(cmd; stdout = console_log, stderr = console_log); wait = false)

println("  status       : RUNNING (PID $(getpid(process)))")
println("  monitor with : tail -f $console_log")
println("=" ^ 78)
