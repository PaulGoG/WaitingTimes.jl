# WaitingTimes.jl

[![Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://PaulGoG.github.io/WaitingTimes.jl/stable/)
[![Release](https://img.shields.io/github/v/release/PaulGoG/WaitingTimes.jl)](https://github.com/PaulGoG/WaitingTimes.jl/releases)
[![Julia](https://img.shields.io/badge/julia-%E2%89%A5%201.12-9558b2?logo=julia&logoColor=white)](https://julialang.org)
[![CI](https://github.com/PaulGoG/WaitingTimes.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/PaulGoG/WaitingTimes.jl/actions/workflows/CI.yml)
[![Coverage](https://codecov.io/gh/PaulGoG/WaitingTimes.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/PaulGoG/WaitingTimes.jl)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![Code style: SciML](https://img.shields.io/static/v1?label=code%20style&message=SciML&color=9558b2&labelColor=389826)](https://github.com/SciML/SciMLStyle)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Paper](https://img.shields.io/badge/paper-10.1088%2F2632--072X%2Fae8aa5-blue)](https://doi.org/10.1088/2632-072X/ae8aa5)

Exact waiting-time distributions of scalar time series for threshold grids:
the numerical backbone of the analyses in P.-A. Gogîță et al., *J. Phys.
Complex.* **7**, 035007 (2026),
[doi:10.1088/2632-072X/ae8aa5](https://doi.org/10.1088/2632-072X/ae8aa5),
and G. T. Pană, P.-A. Gogîță, A. Nicolin-Żaczek, *Rom. J. Phys.* **69**,
111 (2024),
[doi:10.59277/RomJPhys.2024.69.111](https://doi.org/10.59277/RomJPhys.2024.69.111),
rewritten as a package with verified fast kernels, provenance-tracked data
products and interfaces for batch and real-time analysis.

![Survival functions of the waiting times of the Geisenheim wind speed at a
small and a large threshold, with the scale-free and Pareto-Tsallis fits of
the 2024 recipe](docs/src/assets/transition.png)

The two regimes the papers describe, on the Geisenheim hourly wind speed: at
δ = 1 km/h the survival function of the waiting times is scale-free over
three decades, at δ = 32.5 km/h it is Pareto-Tsallis. Both fits use the
recipe of the 2024 analysis (`examples/legacy_fit.jl`) on distributions
computed here; the numbers behind every figure of this page are in
[`docs/src/assets/PROVENANCE.toml`](docs/src/assets/PROVENANCE.toml).

## File structure

```
WaitingTimes.jl/
├── Project.toml, activate.jl     # package environment; activate.jl instantiates it silently
├── src/                          # library: grid, series, kernels, distribution, pipeline
├── ext/                          # Distributions, CairoMakie and GPU-backend extensions
├── scripts/                      # run, launch, prepare, validate, crosscheck, lineage
├── configs/                      # run configurations and dataset descriptors
├── bench/                        # kernel benchmarks (own environment)
├── test/                         # test suite, fixtures, opt-in device tests
├── docs/                         # Documenter site with an executable example
├── examples/                     # worked consumers against MarketTickStreamer.jl and DeepSpaceTelemetry.jl
├── data/                         # gitignored: raw inputs, collections, logs
├── CITATION.cff, CHANGELOG.md, LICENSE, .JuliaFormatter.toml
```

## Formulation

For a series `A₁..A_N` observed at strictly increasing integer times `t₁..t_N`
and a threshold `δ ≥ 0`, the waiting time of index `n` is

    τₙ = t_m − tₙ,   m = min{ m > n : A_m ≥ Aₙ + δ },

the elapsed time to the first observed value at least `δ` above `Aₙ`. Indices
without such an `m` are right-censored and contribute no waiting time.

Values and thresholds are quantised to a decimal grid with `digits` decimals
and handled as integers, so every kernel produces bit-identical results and
the naive forward scan (`NaiveSearch`) is the permanent reference
implementation. Time passes through missing samples and data gaps; gaps are
recorded and reported (`gap_table`, `classify`) and never alter a waiting
time.

Kernels: `SegmentTreeSearch` (default, milliseconds per threshold at millions
of points), `FenwickSweep` (many thresholds per sweep), `StreamingSearch`
(online, for live pipelines), `NaiveSearch` and `GuardedSearch` (reference
kernels), `DeviceSearch` (the naive scan as a KernelAbstractions kernel on
CPU or GPU).

![How the kernels resolve the waiting times of one index on a 48-sample
series: the naive and guarded scans visit every later sample, the segment tree
climbs and descends, the Fenwick sweep answers three thresholds for every
index in one backward pass, the streaming kernel resolves them as packets of
samples arrive](docs/src/assets/kernels.gif)

Every kernel produces the same integer result, which is why the naive scan
can stand as the permanent reference: on the full threshold grids of the six
datasets shipped as configurations (7 124 thresholds, up to 10⁶ points) not
one index differs between any kernel and the reference.

![Wall time per threshold of every kernel on synthetic random walks of 10⁴
to 10⁶ points at three thresholds](docs/src/assets/timings.png)

## The transition across thresholds

![The survival function of the Geisenheim waiting times sweeping through the
threshold grid from 0 to 50 km/h](docs/src/assets/sweep.gif)

A collection holds one distribution per threshold; sweeping the grid is
what the downstream indicators of the 2026 paper (the difference of the two
fits' Kolmogorov–Smirnov distances and the generalised Kullback–Leibler
divergence between their tails) are computed from.

## Setup

Requires Julia 1.12 or later. From a clone:

```
julia activate.jl        # instantiate the package environment
julia -i activate.jl     # the same, then a REPL in it
```

Every script and auxiliary environment activates itself; no `--project` flag
is needed anywhere.

## Entry points

```
julia --threads=auto scripts/run_pipeline.jl --config configs/quickstart.toml   # generate a collection
julia scripts/launch_run.jl --config configs/geisenheim_wind.toml              # detached run, log in data/logs/
julia scripts/prepare.jl --config configs/geisenheim_wind.toml                 # diagnostics and gap table
julia --threads=auto scripts/validate.jl --config configs/quickstart.toml      # configured kernel against the reference kernel
julia --threads=auto scripts/crosscheck.jl --config configs/quickstart.toml    # every kernel against the reference kernel, index by index
julia scripts/lineage.jl data/<collection>                                     # provenance chain
julia --threads=auto test/runtests.jl                                          # test suite
julia --threads=auto bench/run_benchmarks.jl                                   # kernel benchmarks
julia --threads=auto test/device/runtests.jl                                   # opt-in GPU tests (oneAPI)
julia docs/make.jl                                                             # documentation site into docs/build/
JULIA_PKG_USE_CLI_GIT=true julia examples/check_environment.jl                 # instantiate the examples environment (clones two packages)
julia --threads=auto examples/tick_stream.jl                                   # online estimator on a tick stream, checked against batch
julia --threads=3 examples/telemetry_run.jl                                    # telemetry run directory → gaps → collection
julia -e 'using Pkg; Pkg.activate("JuliaFormatter"; shared = true); Pkg.add("JuliaFormatter"); using JuliaFormatter; format(".")'   # formatting
```

Raw inputs are expected under `data/raw/` (gitignored); the configurations in
`configs/` reference them relative to the configuration file. A run writes a
collection directory `data/<collection id>/` holding `config.toml`,
`metadata.toml`, `hardware.txt`, the prepared series, one partition per
threshold under `distributions/`, per-session records and configuration
snapshots under `sessions/`, and the regenerated `index.toml`, `summary.csv`
and `catalog.csv`. Rerunning with a wider threshold grid adds partitions and
appends a session; existing partitions are never rewritten unless
`[output].overwrite = true`, in which case they are backed up first.

Every collection directory carries a `README.md` describing its own files.

Library use, in memory:

```julia
using WaitingTimes
s = QuantizedSeries(values, 4)                 # values::Vector{Union{Missing,Float64}}, 4 decimals
τ = waiting_times(s, 0.0005)                   # SegmentTreeSearch by default; 0 = no passage observed
τ == waiting_times(s, 0.0005, NaiveSearch())   # every kernel is bit-identical to the reference kernel
d = empirical_distribution(τ, threshold(0.0005, s), s)
WaitingTimes.support(d), WaitingTimes.probabilities(d), WaitingTimes.cumulative(d)
```

From a collection on disk, and in real time:

```julia
c = load_collection("data/<collection id>")   # overview when shown; thresholds(c), summary_table(c)
d = distribution(c, "0.0005")                  # one WaitingTimeDistribution
export_legacy(c, "outputData/<id>")           # WTS_<slug>_deltais<δ>.dat files of the 2024 analysis

est = OnlineWaitingTimes([0.5, 5.0], 2; time_unit = :nanosecond, late_policy = :skip)
push!(est, t_ns, price)                        # one sample; snapshot(est) gives the distributions so far
```

## Status

| Component | State |
|---|---|
| Decimal grid, thresholds, series with gaps | done |
| Naive reference kernel and guarded scan (multithreaded) | done |
| Gap classification and class accounting | done |
| Empirical distribution | done |
| Legacy fixture regression (EUR-USD) | done, exact |
| Segment-tree, Fenwick and streaming kernels | done; equal to the reference kernel on every threshold of every dataset grid (7 124 thresholds, up to 10⁶ points) and to 4·10⁶ synthetic points |
| Synthetic generators, benchmarks | done |
| Configuration, storage, provenance, preprocessing, scripts | done; quickstart end to end in the tests |
| Distributions.jl and CairoMakie extensions | done |
| KernelAbstractions device kernel | done; CPU backend in the default tests, oneAPI verified on an Intel Arc GPU |
| Preprocessing after the published treatment (round, fluctuations with denominator and offset, the pruning loop of the 2024 code with the slot kept or deleted, `clip_sigma`) | done; Table 1 of the paper reproduced for the raw datasets |
| Automatic choice of `digits` (`digits = "auto"`, `suggest_digits`, `digits_sensitivity`) | done |
| Collection read side (`load_collection`, `distribution`, `summary_table`, `export_legacy`), per-collection README | done |
| Online estimator for live streams (`OnlineWaitingTimes`) | done; equal to the batch result on every prefix; memory bounded by a declared upper bound or a horizon |
| Worked consumers against MarketTickStreamer.jl and DeepSpaceTelemetry.jl; Table 1 reproduction | done, `examples/` |
| Load latency | precompile workload; first result below 0.1 s after `using WaitingTimes` |
| Documentation site | done |

## How to cite

The package is described by `CITATION.cff`. In BibTeX:

```bibtex
@software{WaitingTimes.jl,
  author  = {Gogîță, Paul-Adrian},
  title   = {WaitingTimes.jl: exact waiting-time distributions of scalar time series},
  year    = {2026},
  version = {0.1.1},
  url     = {https://github.com/PaulGoG/WaitingTimes.jl}
}
```

The method and the datasets are described in the two papers the package
grew out of:

- P.-A. Gogîță, T.-G. Dumitru, F.-I. Constantin, T.-A. Diac, A.-F. Neagoe,
  M.-C. Raportaru, A. Nicolin-Żaczek, Scale-free to Pareto-Tsallis
  transitions in the distributions of waiting times: weather, sea-level,
  currency trading and automotive datasets, *J. Phys. Complex.* **7**, 035007
  (2026), [doi:10.1088/2632-072X/ae8aa5](https://doi.org/10.1088/2632-072X/ae8aa5).
- G. T. Pană, P.-A. Gogîță, A. Nicolin-Żaczek, Waiting times for sea level
  variations in the Port of Trieste: a computational data-driven study,
  *Rom. J. Phys.* **69**, 111 (2024),
  [doi:10.59277/RomJPhys.2024.69.111](https://doi.org/10.59277/RomJPhys.2024.69.111).

The waiting-time definition with a threshold goes back to B. N. Vivirschi,
P. C. Boboc, V. Băran, A. I. Nicolin, *Phys. Scr.* **95**, 044011 (2020),
[doi:10.1088/1402-4896/ab623d](https://doi.org/10.1088/1402-4896/ab623d);
the full list of sources is on the documentation's references page.

<details>
<summary>Full file tree</summary>

```
WaitingTimes.jl/
├── Project.toml                  # package environment (Manifest.toml is not tracked)
├── activate.jl                   # silent activation of the package environment
├── src/
│   ├── WaitingTimes.jl           # module root: imports, includes, exports
│   ├── Quantization.jl           # decimal integer grid, Threshold, formatting
│   ├── Series.jl                 # PreparationRecord, QuantizedSeries with explicit gaps
│   ├── Gaps.jl                   # gap detection and declaration, classification of waits
│   ├── Kernels.jl                # NaiveSearch (reference kernel), GuardedSearch, scan_work
│   ├── SegmentTree.jl            # SegmentTreeSearch, the production kernel
│   ├── FenwickSweep.jl           # FenwickSweep, multi-threshold sweep
│   ├── Streaming.jl              # StreamingSearch, StreamingState, online accumulator
│   ├── Distribution.jl           # WaitingTimeDistribution, empirical_distribution
│   ├── Synthetic.jl              # synthetic series and gap generators for tests and benchmarks
│   ├── Provenance.jl             # config overlays, canonical hashing, identifiers, fingerprints
│   ├── Config.jl                 # TOML schema, validated Settings, threshold grids
│   ├── Naming.jl                 # self-describing file-name grammar and parser
│   ├── Preprocessing.jl          # ingestion (csv/dat/arrow/tick), transforms, diagnostics
│   ├── Monitoring.jl             # terminal and file logging, TTY-gated progress
│   ├── Storage.jl                # per-threshold partitions, index, summary, catalog
│   ├── Orchestrator.jl           # prepare, generate (resume, reference checks), validate
│   ├── Backends.jl               # KernelAbstractions backend registry (CPU + GPU probes)
│   └── DeviceKernels.jl          # DeviceSearch: the naive scan as a device kernel
├── ext/
│   ├── WaitingTimesDistributionsExt.jl   # DiscreteNonParametric view of a distribution
│   ├── WaitingTimesCairoMakieExt.jl      # figure theme, decade ticks, series and distribution figures
│   └── WaitingTimes{CUDA,oneAPI,AMDGPU,Metal}Ext.jl   # GPU backend probes
├── scripts/
│   ├── run_pipeline.jl           # generate or extend a collection from a TOML config
│   ├── launch_run.jl             # detached run with console log under data/logs/
│   ├── prepare.jl                # diagnostics and gap table before a run
│   ├── validate.jl               # configured kernel against the reference kernel
│   ├── crosscheck.jl             # every kernel against the reference kernel, index by index
│   └── lineage.jl                # provenance chain of a collection
├── configs/
│   ├── quickstart.toml           # EUR-USD fixture, ten thresholds, seconds on a laptop
│   ├── eur_usd.toml, geisenheim_wind.toml, trieste_sea_level.toml,
│   │   iss_tec.toml, noaa_solar.toml, trustee_fuel.toml
│   └── datasets/                 # dataset descriptors: source, licence, sampling, checksum
├── data/                         # gitignored: raw/ inputs, collections, logs
├── bench/
│   ├── Project.toml, activate.jl
│   └── run_benchmarks.jl         # kernel timings with exact cross-checks
├── test/
│   ├── Project.toml, activate.jl
│   ├── runtests.jl               # static QA, unit, equivalence, fixture tests
│   ├── pipeline_tests.jl         # provenance, config, preprocessing, storage, end-to-end runs
│   ├── device/                   # opt-in oneAPI tests on a local Intel GPU (own environment)
│   └── fixtures/                 # EUR-USD input and legacy outputs for regression
├── docs/
│   ├── Project.toml, activate.jl, make.jl
│   └── src/                      # formulation, kernels, pipeline, configuration, provenance,
│       └── literate/             #   validation, interfacing, API, references; executable example
├── examples/                     # own environment: the two public packages from GitHub
│   ├── Project.toml, activate.jl, check_environment.jl
│   ├── tick_stream.jl            # Channel{Trade} of MarketTickStreamer.jl → OnlineWaitingTimes, batch check
│   └── telemetry_run.jl          # DeepSpaceTelemetry.jl run directory → series with gaps → collection
├── .github/, codecov.yml         # CI (tests on Julia 1 and pre, coverage, docs deploy), Dependabot
├── CITATION.cff, CHANGELOG.md, LICENSE, .JuliaFormatter.toml
```

</details>
