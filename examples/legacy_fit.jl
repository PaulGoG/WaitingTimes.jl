# The fitting recipe of the 2024 analysis code
# (the parameter optimisation of the 2024 fit code), in substance verbatim:
# Nelder-Mead on the renormalised Kolmogorov-Smirnov distance; the scale-free
# fit started from the maximum-likelihood exponent at every point of the x_min
# sampling grid; the Pareto-Tsallis fit started from (2, mean τ). Included by
# published_fits.jl.
using Optim: Optim, NelderMead, optimize
using WaitingTimes

ks_distance(data_cdf, model_cdf) = maximum(abs.(model_cdf .- data_cdf))

scale_free_cdf(x, α, x_min) = 1 - (x / x_min)^(1 - α)
pareto_tsallis_cdf(x, α, λ) = 1 - (1 + x / λ)^(-α)

function scale_free_loss(α, x_min, τ, cdf)
    x_min = ceil(Int, x_min)
    (x_min > τ[begin] && x_min < τ[end] && α > 1) || return 1.0
    keep = τ .>= x_min
    model = scale_free_cdf.(τ[keep], α, x_min)
    data = cdf[keep] .- cdf[keep][begin]
    model ./= last(model)
    data ./= last(data)
    return ks_distance(data, model)
end

function pareto_tsallis_loss(parameters, τ, cdf)
    α, λ = parameters
    (α > 0 && λ > 0) || return 1.0
    model = pareto_tsallis_cdf.(τ, α, λ) .- pareto_tsallis_cdf(τ[begin], α, λ)
    model ./= last(model)
    return ks_distance(cdf, model)
end

mle_exponent(τ, x_min) = 1 + length(τ) / sum(log.(τ ./ (x_min - 0.5)))

"scale-free fit: the best of the Nelder-Mead runs started on the x_min grid"
function fit_scale_free(τ::Vector{Float64}, cdf::Vector{Float64})
    limit = max(round(Int, log10(maximum(τ)) - 2), 2) - 1
    grid = unique(reduce(vcat, [(10 ^ i):(10 ^ i):(10 ^ (i + 1)) for i in 1:limit]))
    best = (α = 2.0, x_min = minimum(τ), ks = 1.0)
    lock_ = ReentrantLock()
    Threads.@threads for x_start in grid
        tail = τ[τ .>= x_start]
        isempty(tail) && continue
        x0 = [mle_exponent(tail, x_start), Float64(x_start)]
        result = optimize(p -> scale_free_loss(p[1], p[2], τ, cdf), x0, NelderMead())
        lock(lock_) do
            if Optim.minimum(result) < best.ks
                best = (α = Optim.minimizer(result)[1],
                    x_min = ceil(Int, Optim.minimizer(result)[2]),
                    ks = Optim.minimum(result))
            end
        end
    end
    return best
end

"Pareto-Tsallis fit started from (2, mean τ)"
function fit_pareto_tsallis(τ::Vector{Float64}, pmf::Vector{Float64}, cdf::Vector{Float64})
    x0 = [2.0, sum(τ .* pmf)]
    result = optimize(p -> pareto_tsallis_loss(p, τ, cdf), x0, NelderMead())
    return (α = Optim.minimizer(result)[1], λ = Optim.minimizer(result)[2],
        ks = Optim.minimum(result))
end

"support, probability mass, cumulative distribution and the distribution of `series` at `δ`"
function distribution_at(series, δ)
    thr = threshold(δ, series)
    d = empirical_distribution(waiting_times(series, thr), thr, series)
    return Float64.(WaitingTimes.support(d)), WaitingTimes.probabilities(d),
    WaitingTimes.cumulative(d), d
end
