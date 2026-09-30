# Empirical distribution of waiting times at one threshold.

"""
    WaitingTimeDistribution{Tt<:Integer}

Empirical distribution of the waiting times of one series at one threshold:
sorted support, counts, probability mass and cumulative distribution, together
with the accounting of every candidate index. In `:elapsed` mode (the
convention of the original analysis) every observed passage contributes; in
`:exact` mode only passages without an intervening gap do. Under a `horizon`
``H`` waits longer than ``H`` are counted as right-censored, so the support
ends at ``H`` and `n_right_censored` carries the mass beyond it; estimators on
such a distribution must treat it as censored at ``H``.

$(TYPEDFIELDS)
"""
struct WaitingTimeDistribution{Tt <: Integer}
    "threshold"
    delta::Threshold{Int64}
    "time unit of the support"
    time_unit::Symbol
    "`:elapsed` or `:exact`"
    mode::Symbol
    "sorted distinct waiting times"
    support::Vector{Tt}
    "occurrences of each support value"
    counts::Vector{Int}
    "probability mass `counts / nsamples`"
    pmf::Vector{Float64}
    "cumulative distribution ``P(\\tau \\le k)``"
    cdf::Vector{Float64}
    "candidate indices, `N - 1`"
    n_candidates::Int
    "waits with no gap before the passage"
    n_exact::Int
    "waits crossing at least one gap"
    n_gap_crossing::Int
    "indices without an observed passage (within the horizon, when one is set)"
    n_right_censored::Int
    "longest wait counted as observed, in `time_unit`; `nothing` without a horizon"
    horizon::Union{Nothing, Int64}
end

function WaitingTimeDistribution{Tt}(delta, time_unit, mode, support, counts, pmf, cdf,
        n_candidates, n_exact, n_gap_crossing, n_right_censored) where {Tt <: Integer}
    return WaitingTimeDistribution{Tt}(delta, time_unit, mode, support, counts, pmf, cdf,
        n_candidates, n_exact, n_gap_crossing, n_right_censored, nothing)
end

"""
$(TYPEDSIGNATURES)

Empirical distribution of the waiting times `τ` (as returned by
[`waiting_times`](@ref)) of `s` at `δ`. `mode = :elapsed` counts every observed
passage; `mode = :exact` keeps only passages without an intervening gap. With
`horizon = H` (in the time unit of `s`) waits longer than `H` are counted as
right-censored, which reproduces the snapshot of an [`OnlineWaitingTimes`](@ref)
estimator with the same horizon.
"""
function empirical_distribution(
        τ::AbstractVector{Tt}, δ::Threshold, s::QuantizedSeries{Tv, Tt};
        mode::Symbol = :elapsed, horizon::Union{Nothing, Integer} = nothing) where {Tv, Tt}
    mode in (:elapsed, :exact) ||
        throw(ArgumentError("mode must be :elapsed or :exact, got :$mode"))
    horizon === nothing || horizon >= 1 ||
        throw(ArgumentError("horizon must be at least 1, got $horizon"))
    class, _, _ = classify(τ, s)
    if horizon !== nothing
        @inbounds for n in 1:(length(τ) - 1)
            class[n] != CLASS_RIGHT_CENSORED && τ[n] > horizon &&
                (class[n] = CLASS_RIGHT_CENSORED)
        end
    end
    acc = class_counts(class)
    keep = mode === :elapsed ? (CLASS_EXACT, CLASS_GAP_CROSSING) : (CLASS_EXACT,)
    N = length(τ)
    sample = Tt[]
    sizehint!(sample, acc.n_exact + acc.n_gap_crossing)
    @inbounds for n in 1:(N - 1)
        class[n] in keep && push!(sample, τ[n])
    end
    sort!(sample)
    support, counts = run_lengths(sample)
    K = length(sample)
    pmf = K == 0 ? Float64[] : counts ./ K
    cdf = K == 0 ? Float64[] : cumsum(counts) ./ K
    return WaitingTimeDistribution{Tt}(Threshold{Int64}(δ.d, δ.digits), s.time_unit, mode,
        support, counts, pmf, cdf, acc.n_candidates, acc.n_exact, acc.n_gap_crossing,
        acc.n_right_censored, horizon === nothing ? nothing : Int64(horizon))
end

"distinct values and their multiplicities of a sorted vector"
function run_lengths(sorted::AbstractVector{Tt}) where {Tt}
    support = Tt[]
    counts = Int[]
    for v in sorted
        if !isempty(support) && support[end] == v
            counts[end] += 1
        else
            push!(support, v)
            push!(counts, 1)
        end
    end
    return support, counts
end

"sorted distinct waiting times"
support(d::WaitingTimeDistribution) = d.support
"multiplicity of each support value"
counts(d::WaitingTimeDistribution) = d.counts
"probability mass at each support value"
probabilities(d::WaitingTimeDistribution) = d.pmf
"cumulative distribution ``P(\\tau \\le k)`` at each support value"
cumulative(d::WaitingTimeDistribution) = d.cdf
"survival function ``P(\\tau > k)`` at each support value"
survival(d::WaitingTimeDistribution) = 1.0 .- d.cdf
"number of waiting times in the distribution"
nsamples(d::WaitingTimeDistribution) = sum(d.counts)

"""
$(TYPEDSIGNATURES)

Mean waiting time of the distribution (`NaN` when empty).
"""
function mean_waiting_time(d::WaitingTimeDistribution)
    K = nsamples(d)
    K == 0 && return NaN
    return sum(Float64.(d.support) .* d.counts) / K
end
Statistics.mean(d::WaitingTimeDistribution) = mean_waiting_time(d)

Base.length(d::WaitingTimeDistribution) = length(d.support)

"""
$(TYPEDSIGNATURES)

Two distributions are equal when their thresholds, units, modes, supports,
counts, accounting and horizons agree (the probability columns follow from the
counts).
"""
function Base.:(==)(a::WaitingTimeDistribution, b::WaitingTimeDistribution)
    return a.delta == b.delta && a.time_unit === b.time_unit && a.mode === b.mode &&
           a.support == b.support && a.counts == b.counts &&
           a.n_candidates == b.n_candidates && a.n_exact == b.n_exact &&
           a.n_gap_crossing == b.n_gap_crossing &&
           a.n_right_censored == b.n_right_censored && a.horizon == b.horizon
end
function Base.hash(d::WaitingTimeDistribution, h::UInt)
    return hash(
        (d.delta, d.time_unit, d.mode, d.support, d.counts, d.n_candidates,
            d.n_exact, d.n_gap_crossing, d.n_right_censored, d.horizon),
        h)
end

function Base.show(io::IO, d::WaitingTimeDistribution)
    print(io, "WaitingTimeDistribution(δ = ", format_threshold(d.delta), ", ", nsamples(d),
        " waits over ", length(d), " distinct times [", d.time_unit, "], mode = :", d.mode,
        ", censored = ", d.n_right_censored, "/", d.n_candidates,
        d.horizon === nothing ? "" : ", horizon = $(d.horizon)", ")")
end
