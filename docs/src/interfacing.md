# Interfacing from downstream tools

A consumer of this package touches a small surface, in one of three
settings: a series in memory, a collection on disk, or a live stream. The
rest (configuration, provenance, storage layout, orchestration) is
infrastructure for reproducible batch runs.

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
| `WaitingTimes.cumulative(d)` | ``P(\tau \le k)`` (from the integer counts, so it is exact) |
| `WaitingTimes.survival(d)` | ``P(\tau > k)`` |
| `WaitingTimes.nsamples(d)` | number of waiting times |
| `d.n_candidates`, `d.n_exact`, `d.n_gap_crossing`, `d.n_right_censored` | accounting of the indices |
| `d.delta`, `d.time_unit`, `d.mode` | threshold, unit of ``k``, elapsed or exact |

With Distributions.jl loaded, `WaitingTimes.discrete_distribution(d)` is a
`DiscreteNonParametric` with the standard `cdf`, `ccdf`, `quantile`, `mean`
and `rand`; expanding the support by its counts gives the sample itself,
ready for `fit_mle` or any other estimator.

## On disk: a collection

A run of the pipeline writes a collection directory whose `README.md`
describes its own files. From Julia:

```julia
using WaitingTimes

list_collections("data")                  # every collection under a root, as a table
c = load_collection("data/<collection id>")
c                                         # overview: series, steps, thresholds, sessions
thresholds(c)                             # sorted Threshold vector
d = distribution(c, "1.0")                # a WaitingTimeDistribution, by fixed-decimal string,
d = distribution(c, 1.0)                  #   by real value on the grid,
d = distribution(c, threshold(1.0, c.digits))   # or by Threshold
summary_table(c)                          # one row per threshold: counts and statistics
s = load_series(c)                        # the prepared QuantizedSeries
```

Two lower-level readers remain for tabular work:

```julia
using WaitingTimes.Storage: load_distributions, read_index

table = load_distributions(dir)                      # delta, tau, count, pmf, cdf, ccdf
table = load_distributions(dir; deltas = ["1.0"])    # a subset
stats = read_index(dir)                              # per-threshold counts and statistics
```

From any language: the partitions `distributions/delta=<δ>.csv` (or Arrow)
are plain tables with a header row, `delta` in the file name has exactly
`digits` decimals, and `summary.csv` holds the per-threshold statistics.

### The format of the original analysis

Tools written against the 2024 generator read one space-delimited file per
threshold, `WTS_<id>_deltais<δ>.dat`, with the columns `time pdf cdf`.
[`export_legacy`](@ref) writes exactly those files from a collection, so an
existing tool can consume a new collection unchanged:

```julia
export_legacy(c, "outputData/ftEURUSD_clsng_raw"; slug = "ftEURUSD_clsng_raw")
```

## Live: an online estimator

[`OnlineWaitingTimes`](@ref) keeps one streaming state per threshold and
consumes raw `(time, value)` samples; memory is bounded by the pending
indices, not by the length of the stream.

```julia
est = OnlineWaitingTimes([0.5, 5.0, 50.0], 2; time_unit = :nanosecond, late_policy = :skip)
for trade in channel                      # e.g. a Channel{Trade} of MarketTickStreamer.jl
    push!(est, trade.time_ns, trade.price)
end
snapshot(est)                             # Vector{WaitingTimeDistribution}, one per threshold
status(est)                               # per threshold: seen, resolved, pending, mean wait
pending(est)                              # indices without a passage yet, per threshold
```

`push!(est, x)` serves sample-indexed streams; `append!(est, times, values)`
feeds whole batches. A sample whose time does not exceed the previous one is
rejected under `late_policy = :error` or counted in `est.n_late` and skipped
under `:skip`; a consolidated tape interleaves venues, so `:skip` is the
setting for market data. The distributions of a replayed record equal the
batch result of `StreamingSearch`, which equals the reference kernel on
every prefix (tested).

The lower-level pieces remain available: a [`StreamingState`](@ref) at one
threshold fed with [`update!`](@ref), and a
[`DistributionAccumulator`](@ref) turned into a distribution by
[`empirical_distribution`](@ref).

## Worked consumers

`examples/` holds three runnable consumers with their own environment:
`tick_stream.jl` drives the online estimator from a `Channel{Trade}` of
MarketTickStreamer.jl and checks it against the batch result on the same
ticks; `telemetry_run.jl` runs a DeepSpaceTelemetry.jl mission, reads its run
directory into a series with the undelivered batches as recorded gaps and
generates a collection from it; `published_fits.jl` reproduces Table 1 of
the paper with the fitting recipe of the 2024 analysis (`legacy_fit.jl`) on
the shipped configurations. The [Downstream example](@ref) puts the
in-memory pieces together for a model fit.
