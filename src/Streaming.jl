# Streaming search: pending indices wait in a heap keyed by their target value;
# every arriving sample resolves all pending indices whose target it reaches.
# One pass, no lookahead, so it is the kernel for live pipelines and, replayed
# over a stored record, a third independent batch kernel.

"""
    StreamingSearch()

Online kernel. Pending indices are kept in a min-heap keyed by their target
``q_n + d``; when sample ``(t_m, q_m)`` arrives every pending index whose
target is at most ``q_m`` resolves with ``\\tau = t_m - t_n``, then index `m`
joins the heap. Each index is pushed and popped once: ``O(N \\log N)`` per
threshold in a single pass without lookahead. The heap contents are, at any
instant, the indices without an observed passage so far. Replayed over a
stored record the result equals [`NaiveSearch`](@ref) bit for bit, on every
prefix.
"""
struct StreamingSearch <: AbstractSearch end

workspace(::StreamingSearch, ::QuantizedSeries) = nothing

"heap length below which a state with a horizon is never compacted"
const MIN_COMPACTION = 1024

"""
    StreamingState{Tv,Tt}

Mutable state of an online evaluation at one threshold. Feed samples with
[`update!`](@ref); pending indices are those not yet resolved.

Without options the pending set grows as ``E[\\min(\\tau, t)]`` after ``t``
samples: logarithmically for independent values, as ``\\sqrt{t}`` for a random
walk, and linearly when a fraction of the indices never resolves (a downward
drift, or bounded values at a threshold near their range). Two options bound
it. `upper_bound` declares the largest attainable value on the grid: an index
whose target exceeds it cannot resolve and is counted as censored on arrival
instead of being stored, which leaves every result unchanged as long as the
data respect the bound. `horizon` is the longest wait, in time units, kept
pending: an index older than the horizon is evicted and counted as censored,
so resolved waits satisfy ``\\tau \\le H`` and memory stays below twice the
number of samples within one horizon.

$(TYPEDFIELDS)
"""
mutable struct StreamingState{Tv <: Integer, Tt <: Integer}
    "threshold on the grid"
    const delta::Threshold{Tv}
    "largest attainable value on the grid, `nothing` when undeclared"
    const upper_bound::Union{Nothing, Tv}
    "longest wait kept pending, in time units; `nothing` for none"
    const horizon::Union{Nothing, Tt}
    "pending indices as `(target, index, time)`"
    pending::BinaryMinHeap{Tuple{Tv, Int, Tt}}
    "samples seen so far"
    n_seen::Int
    "time of the last sample"
    last_time::Tt
    "indices resolved so far"
    n_resolved::Int
    "indices whose target exceeds `upper_bound`, censored on arrival"
    n_unreachable::Int
    "indices evicted at the horizon without a passage"
    n_evicted::Int
    "heap length at which expired entries are next removed"
    compact_at::Int
end

"""
$(TYPEDSIGNATURES)

Fresh state for threshold `δ` with value type `Tv` and time type `Tt`;
`upper_bound` is on the integer grid, `horizon` in time units.
"""
function StreamingState{Tv, Tt}(
        δ::Threshold; upper_bound::Union{Nothing, Integer} = nothing,
        horizon::Union{Nothing, Integer} = nothing) where {Tv <: Integer, Tt <: Integer}
    horizon === nothing || horizon >= 1 ||
        throw(ArgumentError("horizon must be at least 1, got $horizon"))
    ub = upper_bound === nothing ? nothing : Tv(upper_bound)
    H = horizon === nothing ? nothing : Tt(horizon)
    return StreamingState{Tv, Tt}(Threshold{Tv}(δ.d, δ.digits), ub, H,
        BinaryMinHeap{Tuple{Tv, Int, Tt}}(), 0, zero(Tt), 0, 0, 0, MIN_COMPACTION)
end
function StreamingState(s::QuantizedSeries{Tv, Tt}, δ::Threshold; kwargs...) where {Tv, Tt}
    StreamingState{Tv, Tt}(δ; kwargs...)
end

"""
$(TYPEDSIGNATURES)

Number of indices awaiting a passage (within the horizon, when one is set).
"""
function pending(state::StreamingState)
    state.horizon === nothing || compact!(state)
    return length(state.pending)
end

"""
$(TYPEDSIGNATURES)

Remove the pending indices older than the horizon at the time of the last
sample and count them as evicted. Called by [`update!`](@ref) whenever the
heap has doubled since the previous call, so the cost is amortised
``O(\\log h)`` per sample.
"""
function compact!(state::StreamingState{Tv, Tt}) where {Tv, Tt}
    H = state.horizon
    H === nothing && return state
    entries = extract_all!(state.pending)
    n_before = length(entries)
    t = state.last_time
    filter!(e -> t - e[3] <= H, entries)
    state.n_evicted += n_before - length(entries)
    state.pending = BinaryMinHeap{Tuple{Tv, Int, Tt}}(entries)
    state.compact_at = max(2 * length(entries), MIN_COMPACTION)
    return state
end

"""
$(TYPEDSIGNATURES)

Feed the sample `(t, q)` to the state; `f(n, τ)` is called for every index
`n` resolved by this sample with its waiting time `τ`. Times must strictly
increase between calls, and `q` must not exceed a declared upper bound.
Returns the number of indices resolved.
"""
function update!(f, state::StreamingState{Tv, Tt}, t::Tt, q::Tv) where {Tv, Tt}
    state.n_seen > 0 && t <= state.last_time &&
        throw(ArgumentError(
            "times must strictly increase; got $t after $(state.last_time)",
        ))
    d = state.delta.d
    q <= typemax(Tv) - d || throw(OverflowError(
        "value $q plus threshold $(format_threshold(state.delta)) overflows $Tv",
    ))
    ub, H = state.upper_bound, state.horizon
    ub === nothing || q <= ub ||
        throw(ArgumentError("value $q exceeds the declared upper bound $ub"))
    heap = state.pending
    resolved = 0
    while !isempty(heap) && first(heap)[1] <= q
        _, n, t_n = pop!(heap)
        if H === nothing || t - t_n <= H
            f(n, t - t_n)
            resolved += 1
        else
            state.n_evicted += 1
        end
    end
    state.n_seen += 1
    state.last_time = t
    state.n_resolved += resolved
    if ub === nothing || q + d <= ub
        push!(heap, (q + d, state.n_seen, t))
    else
        state.n_unreachable += 1
    end
    H === nothing || length(heap) < state.compact_at || compact!(state)
    return resolved
end

"""
$(TYPEDSIGNATURES)

Feed the sample `(t, q)` and return the resolved `(index, τ)` pairs.
"""
function update!(state::StreamingState{Tv, Tt}, t::Tt, q::Tv) where {Tv, Tt}
    out = Tuple{Int, Tt}[]
    update!((n, τ) -> push!(out, (n, τ)), state, t, q)
    return out
end

"""
    DistributionAccumulator{Tt}

Incremental counts of waiting times for online evaluation; feed it with
`push!` or through [`update!`](@ref) and turn it into a
[`WaitingTimeDistribution`](@ref) with [`empirical_distribution`](@ref).

$(TYPEDFIELDS)
"""
struct DistributionAccumulator{Tt <: Integer}
    "occurrences of each waiting time"
    counts::Dict{Tt, Int}
end
function DistributionAccumulator{Tt}() where {Tt <: Integer}
    DistributionAccumulator{Tt}(Dict{Tt, Int}())
end

function Base.push!(acc::DistributionAccumulator{Tt}, τ::Integer) where {Tt}
    τ > 0 || throw(ArgumentError("waiting times are positive, got $τ"))
    acc.counts[Tt(τ)] = get(acc.counts, Tt(τ), 0) + 1
    return acc
end

"number of waiting times accumulated"
nsamples(acc::DistributionAccumulator) = sum(values(acc.counts); init = 0)

"""
$(TYPEDSIGNATURES)

Feed the sample `(t, q)` and push every resolved waiting time into `acc`;
returns the number of indices resolved.
"""
function update!(acc::DistributionAccumulator, state::StreamingState{Tv, Tt}, t::Tt, q::Tv) where {
        Tv, Tt}
    update!((_, τ) -> push!(acc, τ), state, t, q)
end

"""
$(TYPEDSIGNATURES)

Distribution of the waiting times accumulated so far, with the accounting of
the streaming state: candidates are the samples seen but the last, resolved
indices count as exact (gaps are not known to a stream), the rest (pending,
evicted at the horizon, above the upper bound) are right-censored.
"""
function empirical_distribution(
        acc::DistributionAccumulator{Tt}, state::StreamingState{Tv, Tt};
        time_unit::Symbol = :sample) where {Tv, Tt}
    support = sort!(collect(keys(acc.counts)))
    counts = [acc.counts[k] for k in support]
    K = sum(counts; init = 0)
    pmf = K == 0 ? Float64[] : counts ./ K
    cdf = K == 0 ? Float64[] : cumsum(counts) ./ K
    n_candidates = max(state.n_seen - 1, 0)
    n_pending = n_candidates - state.n_resolved
    return WaitingTimeDistribution{Tt}(
        Threshold{Int64}(state.delta.d, state.delta.digits), time_unit, :elapsed, support,
        counts, pmf, cdf, n_candidates, state.n_resolved, 0, n_pending,
        state.horizon === nothing ? nothing : Int64(state.horizon))
end

function waiting_times!(τ::AbstractVector{Tt}, s::QuantizedSeries{Tv, Tt}, δ::Threshold,
        ::StreamingSearch; workspace = nothing) where {Tv, Tt}
    q, t = s.values, s.times
    N = length(q)
    length(τ) == N || throw(DimensionMismatch("τ has length $(length(τ)), series has $N"))
    check_threshold(s, δ)
    fill!(τ, zero(Tt))
    state = StreamingState{Tv, Tt}(δ)
    sink = (n, τ_n) -> (@inbounds τ[n] = τ_n)
    @inbounds for m in 1:N
        update!(sink, state, t[m], q[m])
    end
    return τ
end
