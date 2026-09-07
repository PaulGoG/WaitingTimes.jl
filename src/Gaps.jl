# Data gaps: detection, declaration and the post-hoc classification of waiting
# times. Gaps never change a waiting time; they qualify it.

"observed passage with no gap between the index and its passage"
const CLASS_EXACT = 0x01
"observed passage with at least one gap between the index and its passage"
const CLASS_GAP_CROSSING = 0x02
"no passage observed before the end of the record"
const CLASS_RIGHT_CENSORED = 0x03

"""
$(TYPEDSIGNATURES)

Gaps of a strictly increasing time vector under a cadence rule: every pair of
consecutive observations further apart than `cadence` encloses the gap
`[t_k + 1, t_{k+1})`. For a regular series `cadence = 1` marks every missing
sample; for irregular timestamps a larger `cadence` acts as a threshold.
"""
function detect_gaps(times::AbstractVector{Tt}, cadence::Integer) where {Tt <: Integer}
    cadence >= 1 || throw(ArgumentError("cadence must be at least 1, got $cadence"))
    gaps = Tuple{Tt, Tt}[]
    for k in 2:length(times)
        if times[k] - times[k - 1] > cadence
            push!(gaps, (times[k - 1] + one(Tt), times[k]))
        end
    end
    return gaps
end
detect_gaps(s::QuantizedSeries, cadence::Integer) = detect_gaps(s.times, cadence)

"""
$(TYPEDSIGNATURES)

Copy of the series with `intervals` `[start, stop)` merged into its gap list
(declared gaps from schedules, session boundaries or quality logs). Overlapping
intervals are merged; an interval containing an observation is rejected.
"""
function declare_gaps(s::QuantizedSeries{Tv, Tt},
        intervals::AbstractVector{<:Tuple{Integer, Integer}}) where {Tv, Tt}
    merged = sort!(vcat(s.gaps, [(Tt(a), Tt(b)) for (a, b) in intervals]); by = first)
    out = Tuple{Tt, Tt}[]
    for (a, b) in merged
        if !isempty(out) && a <= out[end][2]
            out[end] = (out[end][1], max(out[end][2], b))
        else
            push!(out, (a, b))
        end
    end
    record!(s.record, :declare_gaps,
        Dict{String, Any}("n_intervals" => length(intervals)),
        Dict{String, Any}("n_gaps" => length(out)))
    return QuantizedSeries(
        s.values, s.times, s.digits; gaps = out, time_unit = s.time_unit,
        epoch = s.epoch, record = s.record)
end

"""
$(TYPEDSIGNATURES)

Gaps of the series as named tuples `(start, stop, length)`, longest first.
"""
function gap_table(s::QuantizedSeries)
    rows = [(start = a, stop = b, length = b - a) for (a, b) in s.gaps]
    return sort!(rows; by = r -> r.length, rev = true)
end

"""
$(TYPEDSIGNATURES)

Classify the waiting times `τ` of `s` (sentinel `0` for no observed passage)
against its gap list. Returns `(class, lower, upper)` with `class` one of
`CLASS_EXACT`, `CLASS_GAP_CROSSING`, `CLASS_RIGHT_CENSORED` and the bounds on
the true waiting time: for an exact wait both equal `τ[n]`; for a gap-crossing
wait the lower bound is the elapsed time to the last observation before the
first gap and the upper bound is `τ[n]`; for a right-censored index the lower
bound is the elapsed time to the last observation before the first gap (or to
the end of the record) and the upper bound is `typemax`. Index `N` is never a
candidate and is reported as right-censored with both bounds zero.
"""
function classify(τ::AbstractVector{Tt}, s::QuantizedSeries{Tv, Tt}) where {Tv, Tt}
    N = length(s)
    length(τ) == N || throw(DimensionMismatch("τ has length $(length(τ)), series has $N"))
    times, gaps = s.times, s.gaps
    starts = first.(gaps)
    class = Vector{UInt8}(undef, N)
    lower = Vector{Tt}(undef, N)
    upper = Vector{Tt}(undef, N)
    @inbounds for n in 1:(N - 1)
        t_n = times[n]
        g = searchsortedfirst(starts, t_n + one(Tt))   # first gap starting after t_n
        has_gap = g <= length(starts)
        if τ[n] == 0
            class[n] = CLASS_RIGHT_CENSORED
            lower[n] = has_gap ? last_observation_before(times, starts[g]) - t_n :
                       times[N] - t_n
            upper[n] = typemax(Tt)
        elseif has_gap && starts[g] < t_n + τ[n]
            class[n] = CLASS_GAP_CROSSING
            lower[n] = last_observation_before(times, starts[g]) - t_n
            upper[n] = τ[n]
        else
            class[n] = CLASS_EXACT
            lower[n] = τ[n]
            upper[n] = τ[n]
        end
    end
    class[N] = CLASS_RIGHT_CENSORED
    lower[N] = zero(Tt)
    upper[N] = zero(Tt)
    return class, lower, upper
end

"time of the last observation strictly before `t`"
function last_observation_before(times::AbstractVector{Tt}, t::Tt) where {Tt}
    i = searchsortedfirst(times, t) - 1
    return times[max(i, 1)]
end

"""
$(TYPEDSIGNATURES)

Counts of the classes over the candidate indices `1:N-1`.
"""
function class_counts(class::AbstractVector{UInt8})
    N = length(class)
    n_exact = n_gap = n_cens = 0
    @inbounds for n in 1:(N - 1)
        c = class[n]
        n_exact += c == CLASS_EXACT
        n_gap += c == CLASS_GAP_CROSSING
        n_cens += c == CLASS_RIGHT_CENSORED
    end
    return (n_candidates = N - 1, n_exact = n_exact, n_gap_crossing = n_gap,
        n_right_censored = n_cens)
end
