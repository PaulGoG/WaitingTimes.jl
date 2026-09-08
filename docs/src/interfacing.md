# Interfacing from downstream tools

A consumer of this package touches a small surface. The rest (configuration,
provenance, storage layout, orchestration) is plumbing for reproducible batch
runs.

## In memory: three calls

```julia
using WaitingTimes

s = QuantizedSeries(values, 4)            # values::Vector{Union{Missing,Float64}}, 4 decimals
δ = threshold(0.0005, s)                  # a Threshold on the grid of s
τ = waiting_times(s, δ)                   # Vector{Int64}; 0 = no observed passage
d = empirical_distribution(τ, δ, s)       # WaitingTimeDistribution
```

| Accessor | Meaning |
|---|---|
| `WaitingTimes.support(d)` | sorted distinct waiting times ``k`` |
| `WaitingTimes.counts(d)` | occurrences of each ``k`` |
| `WaitingTimes.probabilities(d)` | ``P(\tau = k)`` |
| `WaitingTimes.cumulative(d)` | ``P(\tau \le k)`` |
| `WaitingTimes.survival(d)` | ``P(\tau > k)`` |
| `WaitingTimes.nsamples(d)` | number of waiting times |
| `d.n_candidates`, `d.n_exact`, `d.n_gap_crossing`, `d.n_right_censored` | accounting of the indices |
| `d.delta`, `d.time_unit`, `d.mode` | threshold, unit of ``k``, elapsed or exact |

With Distributions.jl loaded, `WaitingTimes.discrete_distribution(d)` is a
`DiscreteNonParametric` with the standard `cdf`, `ccdf`, `quantile`, `mean`
and `rand`; expanding the support by its counts gives the sample itself,
ready for `fit_mle` or any other estimator.

## On disk: one table per collection

```julia
using WaitingTimes.Storage: load_distributions, read_index

table = load_distributions(dir)                      # delta, tau, count, pmf, cdf, ccdf
table = load_distributions(dir; deltas = ["1.0"])    # a subset, thresholds as fixed-decimal strings
stats = read_index(dir)                              # per-threshold counts and statistics
```

`delta` is a string with exactly `digits` decimals; `parse_threshold(str, digits)`
turns it back into a `Threshold`, and `digits` is recorded in `series.toml`.
`summary.csv` holds the per-threshold statistics as a plain table. Nothing
else in the directory is needed for analysis.

## Streaming

```julia
state = StreamingState{Int32, Int64}(threshold(0.5, 2))   # value type, time type, δ on a 2-digit grid
acc = DistributionAccumulator{Int64}()
update!(acc, state, t, q)            # one sample (integer time, grid value) resolves pending indices
d = empirical_distribution(acc, state; time_unit = :second)
```

The [Downstream example](@ref) puts the pieces together in a few lines.
