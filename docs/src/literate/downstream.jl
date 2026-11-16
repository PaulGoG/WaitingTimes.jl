# # Downstream example
#
# From a collection on disk to the objects a downstream analysis reads: the
# distribution table, a `WaitingTimeDistribution` with its accounting, and its
# `DiscreteNonParametric` view. Fitting models to these distributions is the
# task of the downstream tools; this package ends here.
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

config = joinpath(pkgdir(WaitingTimes), "configs", "quickstart.toml")
handle = run_pipeline(config; output_dir = mktempdir())
c = load_collection(handle.dir)
table = load_distributions(handle.dir)
first(table, 4)

# ## One distribution and its accounting
#
# Every candidate index is counted once: as an exact wait, a wait across a
# gap, or a right-censored index without an observed passage.

d = distribution(c, "0.0020")
(waits = WaitingTimes.nsamples(d), exact = d.n_exact, gap_crossing = d.n_gap_crossing,
    right_censored = d.n_right_censored, candidates = d.n_candidates)

# Recomputed in memory from the prepared series, the distribution equals the
# stored one.

series = prepare(load_settings(config)).series
δ = threshold(0.002, series)
empirical_distribution(waiting_times(series, δ), δ, series) == d

# ## The Distributions.jl view
#
# Through the Distributions.jl extension the distribution becomes a
# `DiscreteNonParametric`, with the usual methods.

dn = WaitingTimes.discrete_distribution(d)
(mean = mean(dn), median = quantile(dn, 0.5), p_tau_gt_10 = ccdf(dn, 10))

# ## Figure
#
# Survival functions at three thresholds of the collection, in the package
# theme (`WaitingTimes.figure_theme`) with decade ticks
# (`WaitingTimes.decade_ticks`).

fig = with_theme(WaitingTimes.figure_theme()) do
    fig = Figure(; size = (900, 600))
    ax = Axis(fig[1, 1]; xscale = log10, yscale = log10,
        xticks = WaitingTimes.decade_ticks(0, 4), yticks = WaitingTimes.decade_ticks(-4, 0),
        xlabel = "Waiting time k [samples]", ylabel = "P(τ > k)")
    for (key, color, marker) in (("0.0005", "#0072B2", :circle),
        ("0.0020", "#E69F00", :rect), ("0.0050", "#009E73", :utriangle))
        dk = distribution(c, key)
        k = WaitingTimes.support(dk)
        S = WaitingTimes.survival(dk)
        keep = S .> 0
        scatter!(ax, k[keep], S[keep]; color = color, marker = marker, markersize = 10,
            strokecolor = :black, strokewidth = 0.5, label = "δ = " * key)
    end
    Legend(fig[0, 1], ax)
    fig
end
fig
