"""
Logging and progress: a terminal logger teed to a plain-text run log, and
progress bars that stay silent when the output is not a terminal.
"""
module Monitoring

using DocStringExtensions: TYPEDSIGNATURES
using Logging: ConsoleLogger, Debug, Info, Warn, with_logger
using LoggingExtras: FileLogger, MinLevelLogger, TeeLogger
using ProgressMeter: Progress
using TerminalLoggers: TerminalLogger

export with_run_logging, run_progress, log_level

"logging level from a configuration symbol"
function log_level(level::Symbol)
    level === :debug && return Debug
    level === :info && return Info
    level === :warn && return Warn
    throw(ArgumentError("log level must be :debug, :info or :warn, got :$level"))
end

"""
$(TYPEDSIGNATURES)

Run `f()` with a logger that writes to the terminal (a `TerminalLogger` when
`stderr` is a TTY, else a plain `ConsoleLogger`) and appends plain text to
`log_path`, both at `level`.
"""
function with_run_logging(f, log_path::AbstractString; level::Symbol = :info)
    min_level = log_level(level)
    console = stderr isa Base.TTY ? TerminalLogger(stderr, min_level) :
              ConsoleLogger(stderr, min_level)
    file = MinLevelLogger(FileLogger(log_path; append = true), min_level)
    return with_logger(f, TeeLogger(console, file))
end

"""
$(TYPEDSIGNATURES)

Progress bar over `n` steps, enabled only when `stdout` is a terminal.
"""
function run_progress(n::Integer; desc::AbstractString = "thresholds")
    return Progress(n; desc = desc * ": ", dt = 0.5, enabled = stdout isa Base.TTY)
end

end # module
