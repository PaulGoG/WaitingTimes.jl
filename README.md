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
│   ├── Synthetic.jl              # synthetic series for benchmarks and scale tests
│   ├── Provenance.jl             # config overlays, canonical hashing, identifiers, fingerprints
│   ├── Config.jl                 # TOML schema, validated Settings, threshold grids
│   ├── Naming.jl                 # self-describing file-name grammar and parser
│   ├── Preprocessing.jl          # ingestion (csv/dat/arrow/tick), transforms, diagnostics
│   ├── Monitoring.jl             # terminal + file logging, TTY-gated progress
│   ├── Storage.jl                # per-threshold partitions, index, summary, catalog
│   ├── Orchestrator.jl           # prepare, generate (resume, oracle checks), validate
│   ├── Backends.jl               # KernelAbstractions backend registry (CPU + GPU probes)
│   └── DeviceKernels.jl          # DeviceSearch: the naive scan as a device kernel
├── ext/
│   ├── WaitingTimesDistributionsExt.jl   # DiscreteNonParametric view of a distribution
│   ├── WaitingTimesCairoMakieExt.jl      # series and distribution figures with sidecars
│   └── WaitingTimes{CUDA,oneAPI,AMDGPU,Metal}Ext.jl   # GPU backend probes
├── scripts/
│   ├── run_pipeline.jl           # generate or extend a collection from a TOML config
│   ├── launch_run.jl             # detached run with console log under data/logs/
│   ├── prepare.jl                # diagnostics and gap table before a run
│   ├── validate.jl               # configured kernel against the oracle
│   ├── crosscheck.jl             # every kernel against the segment tree, index by index
│   └── lineage.jl                # provenance chain of a collection
├── configs/
│   ├── quickstart.toml           # EUR-USD fixture, ten thresholds, minutes on a laptop
│   ├── geisenheim_wind.toml, trieste_sea_level.toml
│   └── datasets/                 # dataset descriptors: source, licence, sampling, checksum
├── data/                         # gitignored: raw/ inputs, collections, logs
├── bench/
│   ├── Project.toml, activate.jl
│   └── run_benchmarks.jl         # kernel timings with exact cross-checks
├── test/
│   ├── Project.toml, Manifest.toml, activate.jl
│   ├── runtests.jl               # static QA, unit, equivalence, fixture tests
│   ├── pipeline_tests.jl         # provenance, config, preprocessing, storage, end-to-end runs
│   ├── device/                   # opt-in oneAPI tests on a local Intel GPU
│   └── fixtures/                 # EUR-USD input and legacy outputs for regression
├── docs/                         # Documenter site: formulation, kernels, pipeline, configuration,
│                                 #   provenance, validation, interfacing, downstream example, API
│   └── src/literate/             # executable downstream example (Literate.jl)
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

Kernels: `SegmentTreeSearch` (default, milliseconds per threshold at millions
of points), `FenwickSweep` (many thresholds per sweep), `StreamingSearch`
(online, for live pipelines), `GuardedSearch` and `NaiveSearch` (oracles),
`DeviceSearch` (the oracle as a KernelAbstractions kernel on CPU or GPU).

## Setup

Requires Julia 1.12. From a clone:

```julia
julia> include("activate.jl")
```

## Entry points

```julia
julia --threads=auto --project scripts/run_pipeline.jl --config configs/quickstart.toml   # generate a collection
julia --project scripts/launch_run.jl --config configs/geisenheim_wind.toml              # detached run, log in data/logs/
julia --project scripts/prepare.jl --config configs/geisenheim_wind.toml                 # diagnostics and gap table
julia --threads=auto --project scripts/validate.jl --config configs/quickstart.toml      # kernel against the oracle
julia --threads=auto --project=test/device scripts/crosscheck.jl --config configs/quickstart.toml --backend oneapi   # all kernels, index by index
julia --project scripts/lineage.jl data/<collection>                                     # provenance chain
julia --project=. -e 'using Pkg; Pkg.test()'                                             # test suite
julia --threads=auto --project=bench bench/run_benchmarks.jl                              # kernel benchmarks
julia --threads=auto --project=test/device test/device/runtests.jl                        # opt-in GPU tests (oneAPI)
julia --project=docs docs/make.jl                                                        # documentation
julia --project=@JuliaFormatter -e 'using JuliaFormatter; format(".")'                    # formatting
```

Raw inputs are expected under `data/raw/` (gitignored); the configurations in
`configs/` reference them relative to the configuration file. A run writes a
collection directory `data/<collection id>/` holding `config.toml`,
`metadata.toml`, `hardware.txt`, the prepared series, one partition per
threshold under `distributions/`, and the regenerated `index.toml`,
`summary.csv` and `catalog.csv`. Rerunning with a wider threshold grid adds
partitions and appends a session; existing partitions are never rewritten
unless `[output].overwrite = true`, in which case they are backed up first.

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
| Configuration, storage, provenance, preprocessing, scripts | done; quickstart end to end in the tests |
| Distributions.jl and CairoMakie extensions | done |
| KernelAbstractions device kernel | done; CPU backend in the default tests, oneAPI verified on an Intel Arc GPU |
| Documentation site | done |
