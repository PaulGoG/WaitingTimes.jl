# Instantiate the examples environment and report the versions of the two
# public packages it interfaces with.
#
#   JULIA_PKG_USE_CLI_GIT=true julia examples/check_environment.jl
include(joinpath(@__DIR__, "activate.jl"))
using WaitingTimes, MarketTickStreamer, DeepSpaceTelemetry
println("examples environment ready: WaitingTimes ", pkgversion(WaitingTimes),
    ", MarketTickStreamer ", pkgversion(MarketTickStreamer), ", DeepSpaceTelemetry ",
    pkgversion(DeepSpaceTelemetry))
