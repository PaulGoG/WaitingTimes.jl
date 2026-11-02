# In-terminal overview of a raw series: the UnicodePlots methods of
# Preprocessing.terminal_overview.
module WaitingTimesUnicodePlotsExt

using UnicodePlots: UnicodePlots
using WaitingTimes.Preprocessing: Preprocessing, RawSeries, observed

function Preprocessing.terminal_overview(io::IO, rs::RawSeries; width::Integer = 80,
        points::Integer = 2000)
    idx, x = observed(rs)
    isempty(x) && return println(io, "no observed values")
    axis = rs.times === nothing ? collect(Int64, 1:length(rs)) : rs.times
    stride = max(1, length(idx) ÷ points)
    sel = 1:stride:length(idx)
    println(io,
        UnicodePlots.lineplot(Float64.(axis[idx[sel]]), x[sel]; width = width,
            xlabel = "time [$(rs.time_unit)]", ylabel = "value", canvas = UnicodePlots.BrailleCanvas))
    println(io, UnicodePlots.histogram(x; width = width, nbins = 40))
    return nothing
end
function Preprocessing.terminal_overview(rs::RawSeries; kwargs...)
    Preprocessing.terminal_overview(stdout, rs; kwargs...)
end

end # module
