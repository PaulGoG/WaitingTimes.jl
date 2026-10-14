# Summary of a quantised series: size, time span, value statistics, sampling
# step and the gaps by kind.

"""
    SeriesDescription

Summary of a [`QuantizedSeries`](@ref) returned by [`describe`](@ref):
observations, record length in sampling steps, first and last time, value
statistics in data units, grid digits, sampling step, segments, and the number
of gaps with the share of the record they cover, in total and by kind.

$(TYPEDFIELDS)
"""
struct SeriesDescription
    "number of observations"
    n::Int
    "grid positions from the first to the last observation ([`record_length`](@ref))"
    record_length::Int
    "time of the first observation"
    first_time::Int64
    "time of the last observation"
    last_time::Int64
    "time unit"
    time_unit::Symbol
    "smallest value, in data units"
    min::Float64
    "largest value, in data units"
    max::Float64
    "mean value, in data units"
    mean::Float64
    "median value, in data units"
    median::Float64
    "decimal digits of the grid"
    digits::Int
    "sampling step of the time axis ([`sampling_step`](@ref))"
    sampling_step::Int64
    "number of segments ([`segment_lengths`](@ref))"
    n_segments::Int
    "number of gaps"
    n_gaps::Int
    "share of the span from the first to the last observation covered by gaps"
    gap_share::Float64
    "number of gaps and share of the span they cover, by kind"
    gaps_by_kind::Dict{String, @NamedTuple{count::Int, share::Float64}}
end

"""
$(TYPEDSIGNATURES)

Summary of the series `s` as a [`SeriesDescription`](@ref): observations,
record length, first and last time, minimum, maximum, mean and median of the
values in data units, digits, sampling step, segments, and the gaps with the
share of the span `[t_1, t_N]` they cover, in total and by kind. Declared
public, not exported (`WaitingTimes.describe`), as the name is common.
"""
function describe(s::QuantizedSeries)
    scale = 10.0^s.digits
    x = s.values ./ scale
    span = Float64(last(s.times) - first(s.times))
    share(len) = span > 0 ? len / span : 0.0
    by_kind = Dict{String, @NamedTuple{count::Int, share::Float64}}()
    covered = 0
    for ((a, b), kind) in zip(s.gaps, s.gap_kinds)
        covered += b - a
        prev = get(by_kind, kind, (count = 0, share = 0.0))
        by_kind[kind] = (count = prev.count + 1, share = prev.share + share(b - a))
    end
    return SeriesDescription(length(s), record_length(s), first(s.times), last(s.times),
        s.time_unit, minimum(x), maximum(x), Statistics.mean(x), Statistics.median(x),
        s.digits, sampling_step(s), length(segment_lengths(s)), length(s.gaps),
        share(covered), by_kind)
end

function Base.show(io::IO, ::MIME"text/plain", d::SeriesDescription)
    println(io, "SeriesDescription")
    println(
        io, "  observations   ", d.n, " over ", d.record_length, " grid positions (step ",
        d.sampling_step, ", ", d.n_segments, d.n_segments == 1 ? " segment)" : " segments)")
    println(
        io, "  time           ", d.first_time, " to ", d.last_time, " [", d.time_unit, "]")
    println(io, "  values         min ", d.min, ", max ", d.max, ", mean ",
        round(d.mean; sigdigits = 6), ", median ", d.median, " (digits = ", d.digits, ")")
    print(io, "  gaps           ", d.n_gaps, ", ", round(100 * d.gap_share; digits = 2),
        " % of the span")
    for kind in sort!(collect(keys(d.gaps_by_kind)))
        g = d.gaps_by_kind[kind]
        print(io, "\n    ", rpad(kind, 13), g.count, ", ",
            round(100 * g.share; digits = 2), " %")
    end
end
function Base.show(io::IO, d::SeriesDescription)
    print(io, "SeriesDescription(", d.n, " observations, ", d.n_gaps, " gaps, ",
        round(100 * d.gap_share; digits = 2), " % of the span)")
end
