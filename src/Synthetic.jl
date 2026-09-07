"""
Synthetic series for benchmarks and scale tests: random walks with drift,
trend, cycles, noise, jumps and heavy-tailed increments; independent samples;
missing-value injection; irregular time stamps. Every generator takes the
random number generator as its first argument, so callers control
reproducibility (StableRNGs in the tests).
"""
module Synthetic

using DocStringExtensions: TYPEDSIGNATURES
using Random: AbstractRNG, randexp

export random_walk, iid_series, insert_missing, irregular_times

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

end # module
