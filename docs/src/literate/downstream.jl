# # Downstream example
#
# From a collection on disk to a model fit with Distributions.jl, through the
# three objects a consumer touches: the distribution table, the
# `WaitingTimeDistribution`, and its `DiscreteNonParametric` view. Nothing
# here is specific to any analysis.
#
# The example runs on the EUR-USD fixture shipped with the tests, so it
# executes in seconds during the documentation build.

using WaitingTimes
using WaitingTimes.Storage: load_distributions
using Distributions
using CairoMakie

# ## A collection on disk
#
# `scripts/run_pipeline.jl` produces it; here it is written to a temporary
# directory.

handle = run_pipeline(joinpath(pkgdir(WaitingTimes), "configs", "quickstart.toml");
    output_dir = mktempdir())
table = load_distributions(handle.dir)
first(table, 4)

# ## One distribution, in memory
#
# The same object the pipeline wrote, recomputed directly from the series.

settings = load_settings(joinpath(pkgdir(WaitingTimes), "configs", "quickstart.toml"))
series = prepare(settings).series
δ = threshold(0.002, series)
d = empirical_distribution(waiting_times(series, δ), δ, series)

# Through the Distributions.jl extension it becomes a `DiscreteNonParametric`,
# with the usual methods.

dn = WaitingTimes.discrete_distribution(d)
(mean = mean(dn), median = quantile(dn, 0.5), p_tau_gt_10 = ccdf(dn, 10))

# ## A Pareto tail by maximum likelihood
#
# Waiting times are integers, so the tail above ``x_{\min}`` is modelled as a
# continuous power law rounded to the nearest integer. Its exponent is the
# maximum-likelihood estimate for integer data of Clauset, Shalizi and Newman,
# their Eq. (3.7), accurate to about 1 % for ``x_{\min} \gtrsim 6``; the
# continuous formula applied to integers is biased at such small ``x_{\min}``.

sample = [k for (k, c) in zip(WaitingTimes.support(d), WaitingTimes.counts(d)) for _ in 1:c]
x_min = 6
tail = sample[sample .>= x_min]
α = 1 + length(tail) / sum(log.(tail ./ (x_min - 0.5)))
pareto = Pareto(α - 1, x_min - 0.5)

# The Kolmogorov–Smirnov distance compares the empirical tail at every integer
# ``k`` from ``x_{\min}`` to the longest wait with the model at ``k + 1/2``,
# the upper edge of the values that round to ``k``.

tail_dn = WaitingTimes.discrete_distribution(empirical_distribution(
    [τ >= x_min ? τ : 0 for τ in waiting_times(series, δ)], δ, series))
distance = maximum(abs(cdf(pareto, k + 0.5) - cdf(tail_dn, k)) for k in x_min:maximum(tail))
(alpha = α, x_min = x_min, D_KS = distance)

# ## Figure
#
# Survival function of the data with the fitted tail, in the package theme
# (`WaitingTimes.figure_theme`) with decade ticks (`WaitingTimes.decade_ticks`).

k = WaitingTimes.support(d)
S = WaitingTimes.survival(d)
keep = S .> 0
kt = k[k .>= x_min]
fig = with_theme(WaitingTimes.figure_theme()) do
    fig = Figure(; size = (900, 600))
    ax = Axis(fig[1, 1]; xscale = log10, yscale = log10,
        xticks = WaitingTimes.decade_ticks(0, 4), yticks = WaitingTimes.decade_ticks(-4, 0),
        xlabel = "Waiting time k [days]", ylabel = "P(τ > k)")
    scatter!(ax, k[keep], S[keep]; color = :black, strokecolor = :black,
        label = "Data, δ = 0.002")
    lines!(ax, kt, ccdf(dn, x_min - 1) .* ccdf.(pareto, kt .+ 0.5); color = :orangered,
        linestyle = :dash, label = "Pareto tail, α = $(round(α; digits = 2))")
    Legend(fig[0, 1], ax)
    fig
end
fig
