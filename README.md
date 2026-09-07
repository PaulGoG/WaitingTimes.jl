# WaitingTimes.jl

Exact waiting-time distributions of scalar time series for threshold grids.

## File structure

```
WaitingTimes.jl/
├── Project.toml, Manifest.toml   # package environment, pinned
├── activate.jl                   # silent activation of the package environment
├── src/
│   ├── WaitingTimes.jl           # module root: imports, includes, exports
│   ├── Quantization.jl           # decimal integer grid, Threshold, formatting
│   ├── Series.jl                 # PreparationRecord, QuantizedSeries with explicit gaps
│   ├── Gaps.jl                   # gap detection and declaration, classification of waits
│   ├── Kernels.jl                # NaiveSearch (oracle), GuardedSearch, waiting_times!
│   ├── SegmentTree.jl            # SegmentTreeSearch, the production kernel
│   ├── FenwickSweep.jl           # FenwickSweep, multi-threshold sweep
│   ├── Streaming.jl              # StreamingSearch, StreamingState, online accumulator
│   ├── Distribution.jl           # WaitingTimeDistribution, empirical_distribution
│   └── Synthetic.jl              # synthetic series for benchmarks and scale tests
├── bench/
│   ├── Project.toml, activate.jl
│   └── run_benchmarks.jl         # kernel timings with exact cross-checks
├── test/
│   ├── Project.toml, Manifest.toml, activate.jl
│   ├── runtests.jl               # static QA, unit, equivalence, fixture tests
│   └── fixtures/                 # EUR-USD input and legacy outputs for regression
├── docs/                         # Documenter skeleton (Project.toml, activate.jl, make.jl)
├── .github/workflows/            # CI, CompatHelper, TagBot
├── CITATION.bib, CHANGELOG.md, LICENSE, .JuliaFormatter.toml
```

## Formulation

For a series `A₁..A_N` observed at strictly increasing integer times `t₁..t_N`
and a threshold `δ ≥ 0`, the waiting time of index `n` is

    τₙ = t_m − tₙ,   m = min{ m > n : A_m ≥ Aₙ + δ },

the elapsed time to the first observed value at least `δ` above `Aₙ`. Indices
without such an `m` are right-censored and contribute no waiting time.

Values and thresholds are quantised to a decimal grid with `digits` decimals
and handled as integers, so every kernel produces bit-identical results and
the naive forward scan (`NaiveSearch`) is the permanent correctness oracle.
Time passes through missing samples and data gaps; gaps are recorded and
reported (`gap_table`, `classify`) and never alter a waiting time.

## Setup

Requires Julia 1.12. From a clone:

```julia
julia> include("activate.jl")
```

## Entry points

```julia
julia --project=. -e 'using Pkg; Pkg.test()'                        # test suite
julia --threads=auto --project=bench bench/run_benchmarks.jl         # kernel benchmarks
julia --project=docs docs/make.jl                                   # documentation
julia --project=@JuliaFormatter -e 'using JuliaFormatter; format(".")'  # formatting
```

Library use:

```julia
using WaitingTimes
s = QuantizedSeries(values, 4)                 # values::Vector{Union{Missing,Float64}}, 4 decimals
τ = waiting_times(s, 0.0005)                   # SegmentTreeSearch by default; 0 = no passage observed
τ == waiting_times(s, 0.0005, NaiveSearch())   # every kernel is bit-identical to the oracle
d = empirical_distribution(τ, threshold(0.0005, s), s)
WaitingTimes.support(d), WaitingTimes.probabilities(d), WaitingTimes.cumulative(d)
```

## Status

| Component | State |
|---|---|
| Decimal grid, thresholds, series with gaps | done |
| Naive oracle and guarded scan (multithreaded) | done |
| Gap classification and class accounting | done |
| Empirical distribution | done |
| Legacy fixture regression (EUR-USD) | done, exact |
| Segment-tree, Fenwick and streaming kernels | done, exact against the oracle to 4·10⁶ points |
| Synthetic generators, benchmarks | done |
| Configuration, storage, provenance, preprocessing, scripts | planned |
| KernelAbstractions device kernel | planned |
| Documentation site | planned |
