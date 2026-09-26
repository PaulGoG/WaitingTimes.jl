# Online estimation: one streaming state and one accumulator per threshold,
# fed with raw (time, value) samples, for embedding in real-time pipelines.

"""
    OnlineWaitingTimes(deltas, digits; time_unit = :sample, value_type = Int64,
                       time_type = Int64, late_policy = :error)

Online estimator of the waiting-time distributions of a scalar stream at
several thresholds. Samples arrive as `(t, x)` with an integer time `t` in
`time_unit` and a real value `x`; `x` is quantised to the `digits` grid and
fed to one [`StreamingState`](@ref) per threshold, whose resolved waits are
counted by a [`DistributionAccumulator`](@ref). Memory is bounded by the
number of pending indices, not by the length of the stream.

`late_policy` governs a sample whose time does not exceed the previous one
(a late print on an interleaved tape): `:error` throws, `:skip` counts it in
`n_late` and ignores it.

Feed with [`push!`](@ref) (`push!(est, t, x)`, or `push!(est, x)` on a
sample-indexed stream); read with [`snapshot`](@ref) (the distributions so
far), [`pending`](@ref) and [`status`](@ref).
"""
mutable struct OnlineWaitingTimes{Tv <: Integer, Tt <: Integer}
    const digits::Int
    const time_unit::Symbol
    const thresholds::Vector{Threshold{Tv}}
    const states::Vector{StreamingState{Tv, Tt}}
    const accumulators::Vector{DistributionAccumulator{Tt}}
    const late_policy::Symbol
    "samples accepted"
    n_seen::Int
    "samples rejected for a non-increasing time"
    n_late::Int
    "time of the last accepted sample"
    last_time::Tt
end

function OnlineWaitingTimes(deltas::AbstractVector, digits::Integer;
        time_unit::Symbol = :sample, value_type::Type{Tv} = Int64,
        time_type::Type{Tt} = Int64, late_policy::Symbol = :error) where {
        Tv <: Integer, Tt <: Integer}
    isempty(deltas) && throw(ArgumentError("at least one threshold is required"))
    time_unit in TIME_UNITS ||
        throw(ArgumentError("time_unit must be one of $(TIME_UNITS), got :$time_unit"))
    late_policy in (:error, :skip) ||
        throw(ArgumentError("late_policy must be :error or :skip, got :$late_policy"))
    thresholds = Threshold{Tv}[Threshold{Tv}(threshold(δ, digits).d, digits)
                               for δ in deltas]
    allunique(thresholds) || throw(ArgumentError("thresholds must be distinct"))
    states = [StreamingState{Tv, Tt}(δ) for δ in thresholds]
    accumulators = [DistributionAccumulator{Tt}() for _ in thresholds]
    return OnlineWaitingTimes{Tv, Tt}(check_digits(digits), time_unit, thresholds, states,
        accumulators, late_policy, 0, 0, zero(Tt))
end

"quantise one real value to the grid of the estimator, as `quantize` does"
function grid_value(est::OnlineWaitingTimes{Tv}, x::Real) where {Tv}
    isfinite(x) || throw(ArgumentError("non-finite value $x"))
    scaled = round(Float64(x); digits = est.digits) * 10.0^est.digits
    abs(scaled) < 9.0e18 || throw(ArgumentError("value $x overflows the integer grid"))
    q = round(Int64, scaled)
    (typemin(Tv) <= q <= typemax(Tv)) ||
        throw(OverflowError("value $x does not fit the value type $Tv"))
    return Tv(q)
end

"""
$(TYPEDSIGNATURES)

Feed the sample `(t, x)`; returns the number of waiting times resolved across
all thresholds. A time not exceeding the last accepted one follows
`late_policy`.
"""
function Base.push!(est::OnlineWaitingTimes{Tv, Tt}, t::Integer, x::Real) where {Tv, Tt}
    if est.n_seen > 0 && t <= est.last_time
        est.late_policy === :error && throw(ArgumentError(
            "time $t does not exceed the last accepted time $(est.last_time)",
        ))
        est.n_late += 1
        return 0
    end
    q = grid_value(est, x)
    resolved = 0
    for (state, acc) in zip(est.states, est.accumulators)
        resolved += update!(acc, state, Tt(t), q)
    end
    est.n_seen += 1
    est.last_time = Tt(t)
    return resolved
end

"""
$(TYPEDSIGNATURES)

Feed the value `x` at the next sample index (`time_unit = :sample`).
"""
function Base.push!(est::OnlineWaitingTimes, x::Real)
    est.time_unit === :sample ||
        throw(ArgumentError("a time is required for time_unit = :$(est.time_unit)"))
    return push!(est, est.n_seen + 1, x)
end

"""
$(TYPEDSIGNATURES)

Feed every `(t, x)` pair of the iterables in order; returns the total number
of waiting times resolved.
"""
function Base.append!(est::OnlineWaitingTimes, times, values)
    total = 0
    for (t, x) in zip(times, values)
        total += push!(est, t, x)
    end
    return total
end

"""
$(TYPEDSIGNATURES)

Indices without an observed passage so far, per threshold in threshold
order; the latest sample is always among them.
"""
pending(est::OnlineWaitingTimes) = [pending(state) for state in est.states]

"""
$(TYPEDSIGNATURES)

The distributions accumulated so far, one [`WaitingTimeDistribution`](@ref)
per threshold in threshold order; each carries the accounting of its state
(candidates, resolved, pending).
"""
function snapshot(est::OnlineWaitingTimes)
    return [empirical_distribution(acc, state; time_unit = est.time_unit)
            for (acc, state) in zip(est.accumulators, est.states)]
end

"""
$(TYPEDSIGNATURES)

Per-threshold status as a vector of named tuples `(delta, n_seen, resolved,
pending, mean_waiting_time)`.
"""
function status(est::OnlineWaitingTimes)
    return [(delta = format_threshold(δ), n_seen = est.n_seen,
                resolved = state.n_resolved,
                pending = pending(state),
                mean_waiting_time = mean_waiting_time(acc))
            for (δ, state, acc) in zip(est.thresholds, est.states, est.accumulators)]
end

"""
$(TYPEDSIGNATURES)

Mean of the waiting times accumulated so far (`NaN` when none).
"""
function mean_waiting_time(acc::DistributionAccumulator)
    K = nsamples(acc)
    K == 0 && return NaN
    return sum(Float64(k) * c for (k, c) in acc.counts) / K
end

function Base.show(io::IO, est::OnlineWaitingTimes{Tv, Tt}) where {Tv, Tt}
    print(io, "OnlineWaitingTimes{", Tv, ",", Tt, "}(", length(est.thresholds),
        " thresholds, digits = ", est.digits, ", unit = :", est.time_unit, ", ",
        est.n_seen, " samples, ", est.n_late, " late, pending = ", sum(pending(est)), ")")
end
