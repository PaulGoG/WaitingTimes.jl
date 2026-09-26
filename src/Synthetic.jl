"""
Synthetic series for benchmarks and scale tests: random walks with drift,
trend, cycles, noise, jumps and heavy-tailed increments; independent samples;
irregular time stamps; and sample-level gap generators modelled on
telemetry links (contact-window duty cycles, Bernoulli and Gilbert-Elliott
packet loss, scheduled disruptions with blackout and recovery). Every
generator takes the random number generator as its first argument where
randomness is involved, so callers control reproducibility.
"""
module Synthetic

using DocStringExtensions: TYPEDFIELDS, TYPEDSIGNATURES
using Random: AbstractRNG, randexp

export random_walk, iid_series, insert_missing, irregular_times
export duty_cycle_mask, bernoulli_mask, gilbert_elliott_mask, stationary_loss_rate,
       Disruption, disruption_mask, apply_mask, gap_scenario

# --- series ------------------------------------------------------------------

"""
$(TYPEDSIGNATURES)

Random walk of length `N`: increments `drift + sigma·ξ` with ξ standard
normal, or symmetric Pareto with tail index `tail_alpha` when given; plus a
linear `trend` per step, sinusoidal `periods` as `(period, amplitude)` pairs,
additive Gaussian `noise`, and jumps of scale `jump_scale` with probability
`jump_probability` per step. The walk starts at `level`.
"""
function random_walk(rng::AbstractRNG, N::Integer; drift::Real = 0.0, sigma::Real = 1.0,
        tail_alpha::Union{Nothing, Real} = nothing, trend::Real = 0.0,
        periods = (), noise::Real = 0.0, jump_probability::Real = 0.0,
        jump_scale::Real = 0.0, level::Real = 0.0)
    N >= 1 || throw(ArgumentError("N must be positive, got $N"))
    sigma >= 0 || throw(ArgumentError("sigma must be non-negative, got $sigma"))
    tail_alpha === nothing || tail_alpha > 0 ||
        throw(ArgumentError("tail_alpha must be positive, got $tail_alpha"))
    0 <= jump_probability <= 1 ||
        throw(ArgumentError("jump_probability must lie in [0, 1], got $jump_probability"))
    x = Vector{Float64}(undef, N)
    value = float(level)
    for n in 1:N
        increment = tail_alpha === nothing ? sigma * randn(rng) :
                    sigma * pareto_increment(rng, tail_alpha)
        value += drift + increment
        if jump_probability > 0 && rand(rng) < jump_probability
            value += jump_scale * randn(rng)
        end
        y = value + trend * n
        for (period, amplitude) in periods
            y += amplitude * sin(2π * n / period)
        end
        y += noise * randn(rng)
        x[n] = y
    end
    return x
end

"symmetric Pareto-tailed increment with tail index `α`"
function pareto_increment(rng::AbstractRNG, α::Real)
    (rand(rng) < 0.5 ? -1 : 1) * (rand(rng)^(-1 / α) - 1)
end

"""
$(TYPEDSIGNATURES)

Independent samples of length `N`: `:normal` (standard), `:uniform` on `[0, 1)`,
or `:exponential` (unit rate).
"""
function iid_series(rng::AbstractRNG, N::Integer; distribution::Symbol = :normal)
    N >= 1 || throw(ArgumentError("N must be positive, got $N"))
    distribution === :normal && return randn(rng, N)
    distribution === :uniform && return rand(rng, N)
    distribution === :exponential && return randexp(rng, N)
    throw(ArgumentError("distribution must be :normal, :uniform or :exponential, got :$distribution"))
end

"""
$(TYPEDSIGNATURES)

Copy of `x` with `n_runs` runs of missing values of random length between 1
and `max_length`, placed at random positions (runs may merge).
"""
function insert_missing(rng::AbstractRNG, x::AbstractVector{<:Real}, n_runs::Integer;
        max_length::Integer = 10)
    n_runs >= 0 || throw(ArgumentError("n_runs must be non-negative, got $n_runs"))
    max_length >= 1 || throw(ArgumentError("max_length must be positive, got $max_length"))
    y = Vector{Union{Missing, Float64}}(x)
    N = length(y)
    for _ in 1:n_runs
        start = rand(rng, 1:N)
        stop = min(N, start + rand(rng, 1:max_length) - 1)
        y[start:stop] .= missing
    end
    return y
end

"""
$(TYPEDSIGNATURES)

Strictly increasing integer time stamps with exponentially distributed
inter-arrival times of mean `mean_interval` (rounded up to at least one unit),
starting at `origin`.
"""
function irregular_times(rng::AbstractRNG, N::Integer; mean_interval::Real = 5.0,
        origin::Integer = 1)
    N >= 1 || throw(ArgumentError("N must be positive, got $N"))
    mean_interval >= 1 ||
        throw(ArgumentError("mean_interval must be at least 1, got $mean_interval"))
    t = Vector{Int64}(undef, N)
    t[1] = origin
    for n in 2:N
        t[n] = t[n - 1] + max(1, round(Int64, randexp(rng) * mean_interval))
    end
    return t
end

# --- gap generators ----------------------------------------------------------
# Sample-level masks (`true` = observed) modelled on the downlink of a
# duty-cycled telemetry link: periodic contact windows, stochastic packet
# loss, and scheduled disruptions. Composed masks turn a complete series into
# one with gaps of realistic structure.

"""
$(TYPEDSIGNATURES)

Periodic contact-window mask: within every `period` samples the first
`round(on_fraction * period)` are observed, the rest are not; `phase` shifts
the pattern. A daily eight-hour window on hourly data is
`duty_cycle_mask(N; period = 24, on_fraction = 8 / 24)`.
"""
function duty_cycle_mask(N::Integer; period::Integer, on_fraction::Real, phase::Integer = 0)
    N >= 1 || throw(ArgumentError("N must be positive, got $N"))
    period >= 1 || throw(ArgumentError("period must be positive, got $period"))
    0 <= on_fraction <= 1 ||
        throw(ArgumentError("on_fraction must lie in [0, 1], got $on_fraction"))
    on = round(Int, on_fraction * period)
    return [mod(n - 1 + phase, period) < on for n in 1:N]
end

"""
$(TYPEDSIGNATURES)

Memoryless packet loss: every sample is lost independently with probability
`p_loss`. Returns the observation mask.
"""
function bernoulli_mask(rng::AbstractRNG, N::Integer; p_loss::Real)
    N >= 1 || throw(ArgumentError("N must be positive, got $N"))
    0 <= p_loss <= 1 || throw(ArgumentError("p_loss must lie in [0, 1], got $p_loss"))
    return [rand(rng) >= p_loss for _ in 1:N]
end

"""
$(TYPEDSIGNATURES)

Bursty packet loss of the Gilbert-Elliott channel: a two-state Markov chain
alternates between a good state (loss probability `p_loss_good`) and a bad
state (`p_loss_bad`) with transition probabilities `p_good_to_bad` and
`p_bad_to_good` per sample. Returns the observation mask. The long-run loss
rate is [`stationary_loss_rate`](@ref).
"""
function gilbert_elliott_mask(rng::AbstractRNG, N::Integer; p_good_to_bad::Real,
        p_bad_to_good::Real, p_loss_good::Real, p_loss_bad::Real, start_bad::Bool = false)
    N >= 1 || throw(ArgumentError("N must be positive, got $N"))
    for (name, p) in (("p_good_to_bad", p_good_to_bad), ("p_bad_to_good", p_bad_to_good),
        ("p_loss_good", p_loss_good), ("p_loss_bad", p_loss_bad))
        0 <= p <= 1 || throw(ArgumentError("$name must lie in [0, 1], got $p"))
    end
    mask = Vector{Bool}(undef, N)
    bad = start_bad
    for n in 1:N
        if bad
            rand(rng) < p_bad_to_good && (bad = false)
        else
            rand(rng) < p_good_to_bad && (bad = true)
        end
        mask[n] = rand(rng) >= (bad ? p_loss_bad : p_loss_good)
    end
    return mask
end

"""
$(TYPEDSIGNATURES)

Long-run loss probability of the Gilbert-Elliott channel,
``\\pi_{\\mathrm{bad}}\\, p_{\\mathrm{bad}} + (1 - \\pi_{\\mathrm{bad}})\\, p_{\\mathrm{good}}``
with ``\\pi_{\\mathrm{bad}} = p_{g \\to b} / (p_{g \\to b} + p_{b \\to g})``.
"""
function stationary_loss_rate(;
        p_good_to_bad::Real, p_bad_to_good::Real, p_loss_good::Real,
        p_loss_bad::Real)
    denominator = p_good_to_bad + p_bad_to_good
    denominator == 0 && return float(p_loss_good)
    π_bad = p_good_to_bad / denominator
    return π_bad * p_loss_bad + (1 - π_bad) * p_loss_good
end

"""
    Disruption

A scheduled link disruption in sample units: from `start` for `duration`
samples the link is degraded by `severity` (1 = full blackout, every sample
lost; below 1, each sample is lost with probability `severity`), then over
`recovery` samples the loss probability ramps linearly back to zero.
Overlapping disruptions compose as the maximum loss probability.

$(TYPEDFIELDS)
"""
struct Disruption
    "first affected sample"
    start::Int
    "length of the blackout phase in samples"
    duration::Int
    "length of the linear recovery ramp in samples"
    recovery::Int
    "loss probability during the blackout, 1 for a full blackout"
    severity::Float64
    function Disruption(start::Integer, duration::Integer, recovery::Integer, severity::Real)
        start >= 1 || throw(ArgumentError("start must be at least 1, got $start"))
        duration >= 1 || throw(ArgumentError("duration must be positive, got $duration"))
        recovery >= 0 ||
            throw(ArgumentError("recovery must be non-negative, got $recovery"))
        0 <= severity <= 1 ||
            throw(ArgumentError("severity must lie in [0, 1], got $severity"))
        return new(Int(start), Int(duration), Int(recovery), Float64(severity))
    end
end

"loss probability of the disruption at sample `n`"
function loss_probability(d::Disruption, n::Integer)
    n < d.start && return 0.0
    n < d.start + d.duration && return d.severity
    n < d.start + d.duration + d.recovery || return 0.0
    progress = (n - d.start - d.duration + 1) / (d.recovery + 1)
    return d.severity * (1 - progress)
end

"""
$(TYPEDSIGNATURES)

Observation mask of scheduled disruptions: a full blackout (`severity = 1`)
removes every sample of its phase deterministically; partial blackouts and
recovery ramps lose samples at the composed loss probability.
"""
function disruption_mask(rng::AbstractRNG, N::Integer, disruptions::AbstractVector{Disruption})
    N >= 1 || throw(ArgumentError("N must be positive, got $N"))
    mask = trues(N)
    for n in 1:N
        p = maximum((loss_probability(d, n) for d in disruptions); init = 0.0)
        p == 0 && continue
        mask[n] = p >= 1 ? false : rand(rng) >= p
    end
    return mask
end

"""
$(TYPEDSIGNATURES)

Series with `missing` where the mask is `false`.
"""
function apply_mask(x::AbstractVector{<:Real}, mask::AbstractVector{Bool})
    length(x) == length(mask) ||
        throw(DimensionMismatch("series ($(length(x))) and mask ($(length(mask))) differ"))
    y = Vector{Union{Missing, Float64}}(x)
    y[.!mask] .= missing
    return y
end

"""
$(TYPEDSIGNATURES)

Compose a gap scenario on `x`: a contact-window duty cycle (`period`,
`on_fraction`), a loss channel (`:none`, `:bernoulli` with `p_loss`, or
`:gilbert_elliott` with its four probabilities) and scheduled `disruptions`.
Returns the masked series and the mask.
"""
function gap_scenario(rng::AbstractRNG, x::AbstractVector{<:Real};
        period::Union{Nothing, Integer} = nothing, on_fraction::Real = 1.0,
        phase::Integer = 0, loss::Symbol = :none, p_loss::Real = 0.0,
        p_good_to_bad::Real = 0.0, p_bad_to_good::Real = 1.0, p_loss_good::Real = 0.0,
        p_loss_bad::Real = 0.0, disruptions::AbstractVector{Disruption} = Disruption[])
    N = length(x)
    mask = period === nothing ? trues(N) :
           duty_cycle_mask(N; period = period, on_fraction = on_fraction, phase = phase)
    if loss === :bernoulli
        mask .&= bernoulli_mask(rng, N; p_loss = p_loss)
    elseif loss === :gilbert_elliott
        mask .&= gilbert_elliott_mask(rng, N; p_good_to_bad, p_bad_to_good, p_loss_good,
            p_loss_bad)
    elseif loss !== :none
        throw(ArgumentError("loss must be :none, :bernoulli or :gilbert_elliott, got :$loss"))
    end
    isempty(disruptions) || (mask .&= disruption_mask(rng, N, disruptions))
    any(mask) || throw(ArgumentError("the scenario removes every sample"))
    return apply_mask(x, mask), mask
end

end # module
