# # Downstream example
#
# The shortest path from a collection on disk to a model fit with
# Distributions.jl. Nothing here is specific to any analysis; it shows the
# three things a consumer touches: the distribution table, the
# `WaitingTimeDistribution`, and its `DiscreteNonParametric` view.
#
# The example runs on the EUR-USD fixture shipped with the tests, so it
# executes in seconds during the documentation build.

using WaitingTimes
using WaitingTimes.Storage: load_distributions
using Distributions
using CairoMakie

# ## A collection on disk
#
# Normally produced by `scripts/run_pipeline.jl`; here in a temporary
# directory.

handle = run_pipeline(joinpath(pkgdir(WaitingTimes), "configs", "quickstart.toml");
    output_dir = mktempdir())
table = load_distributions(handle.dir)
first(table, 4)

# ## One distribution, in memory
#
# The same object the pipeline wrote, recomputed directly from the series.

series, _ = prepare(load_settings(joinpath(pkgdir(WaitingTimes), "configs", "quickstart.toml")))
δ = threshold(0.002, series)
d = empirical_distribution(waiting_times(series, δ), δ, series)

# Through the Distributions.jl extension it becomes a `DiscreteNonParametric`,
# with the usual methods.

dn = WaitingTimes.discrete_distribution(d)
(mean = mean(dn), median = quantile(dn, 0.5), p_tau_gt_10 = ccdf(dn, 10))

# ## A Pareto tail by maximum likelihood
#
# Expand the counts into a sample, keep the tail above ``x_{\min}``, and let
# Distributions.jl estimate the shape. The distance between the fitted and
# the empirical cumulative distributions over the tail is one line.

sample = [k for (k, c) in zip(WaitingTimes.support(d), WaitingTimes.counts(d)) for _ in 1:c]
x_min = 5
tail = sample[sample .>= x_min]
pareto = fit_mle(Pareto, tail)

#-

tail_dn = WaitingTimes.discrete_distribution(empirical_distribution(
    [τ >= x_min ? τ : 0 for τ in waiting_times(series, δ)], δ, series))
distance = maximum(abs(cdf(pareto, k) - cdf(tail_dn, k)) for k in support(tail_dn))
(alpha = shape(pareto) + 1, x_min = scale(pareto), D_KS = distance)

# ## Figure
#
# Survival function of the data with the fitted tail: data as black markers,
# fit as a dashed line from ``x_{\min}``; boxed axes, no title, legend on top.

k = WaitingTimes.support(d)
S = WaitingTimes.survival(d)
keep = S .> 0
kt = k[k .>= x_min]
fig = Figure(; size = (600, 400), fontsize = 13)
ax = Axis(fig[1, 1]; xscale = log10, yscale = log10,
    xlabel = "Waiting time k [days]", ylabel = "P(τ > k)",
    xgridstyle = :dash, ygridstyle = :dash, xgridcolor = (:grey, 0.12), ygridcolor = (
        :grey, 0.12),
    xminorticksvisible = false, yminorticksvisible = false, xtickalign = 1, ytickalign = 1,
    topspinevisible = true, rightspinevisible = true)
scatter!(ax, k[keep], S[keep]; color = :black, markersize = 5, label = "Data, δ = 0.002")
lines!(
    ax, kt, ccdf(dn, x_min - 1) .* ccdf.(pareto, kt); color = :orangered, linestyle = :dash,
    linewidth = 2, label = "Pareto tail, α = $(round(shape(pareto) + 1; digits = 2))")
Legend(fig[0, 1], ax; orientation = :horizontal, framevisible = false)
fig
