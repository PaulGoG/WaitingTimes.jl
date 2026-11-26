# WaitingTimes.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://PaulGoG.github.io/WaitingTimes.jl/stable/)
[![CI](https://github.com/PaulGoG/WaitingTimes.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/PaulGoG/WaitingTimes.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/PaulGoG/WaitingTimes.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/PaulGoG/WaitingTimes.jl)
[![Aqua QA](https://juliatesting.github.io/Aqua.jl/dev/assets/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![JET](https://img.shields.io/badge/tested%20with-JET.jl-233f9a)](https://github.com/aviatesk/JET.jl)
[![Code Style: SciML](https://img.shields.io/static/v1?label=code%20style&message=SciML&color=9558b2&labelColor=389826)](https://github.com/SciML/SciMLStyle)
[![Format](https://github.com/PaulGoG/WaitingTimes.jl/actions/workflows/Format.yml/badge.svg?branch=main)](https://github.com/PaulGoG/WaitingTimes.jl/actions/workflows/Format.yml?query=branch%3Amain)
[![Julia](https://img.shields.io/badge/dynamic/toml?url=https%3A%2F%2Fraw.githubusercontent.com%2FPaulGoG%2FWaitingTimes.jl%2Fmain%2FProject.toml&query=%24.compat.julia&label=julia&color=9558b2)](https://julialang.org/downloads/)
[![DOI](https://img.shields.io/badge/DOI-10.1088%2F2632--072X%2Fae8aa5-blue)](https://doi.org/10.1088/2632-072X/ae8aa5)

Exact waiting-time distributions of scalar time series for threshold grids.
The package is my rewrite of the code behind the analyses in
P.-A. Gogîță et al., *J. Phys. Complex.* **7**, 035007 (2026),
[doi:10.1088/2632-072X/ae8aa5](https://doi.org/10.1088/2632-072X/ae8aa5),
and G. T. Pană, P.-A. Gogîță, A. Nicolin-Żaczek, *Rom. J. Phys.* **69**,
111 (2024),
[doi:10.59277/RomJPhys.2024.69.111](https://doi.org/10.59277/RomJPhys.2024.69.111).
Every fast kernel is checked index by index against a naive reference scan.
The results are written as collections that carry their own provenance, and
an online estimator follows the same distributions on a live stream. The
package ends at the distributions: fitting models to them, as the papers do,
is left to the downstream tools that read the collections.

## File structure

```
WaitingTimes.jl/
├── Project.toml, activate.jl     # package environment; activate.jl instantiates it silently
├── src/                          # library: grid, series, kernels, distribution, pipeline
├── ext/                          # Distributions, CairoMakie, UnicodePlots, KernelAbstractions and GPU-backend extensions
├── scripts/                      # run, launch, prepare, validate, crosscheck, lineage
├── configs/                      # run configurations and dataset descriptors
├── bench/                        # kernel benchmarks (own environment)
├── test/                         # test suite, fixtures, opt-in device tests
├── docs/                         # Documenter site with an executable example
├── examples/                     # worked consumers of the two producers
├── data/                         # gitignored: raw inputs, collections, logs
└── CITATION.cff, CHANGELOG.md, LICENSE, .JuliaFormatter.toml, .gitattributes
```

## Setup

Requires Julia 1.12 or later. The package is not registered; as a dependency
it is added by URL:

```julia
using Pkg
Pkg.add(url = "https://github.com/PaulGoG/WaitingTimes.jl")
```

From a clone:

```
julia activate.jl        # instantiate the package environment
julia -i activate.jl     # the same, then a REPL in it
```

Every script and auxiliary environment activates itself; no `--project` flag
is needed. The scripts run in their own environment, `scripts/`, instantiated
on first use like the others.

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
julia --threads=auto examples/tick_stream.jl                                   # MarketTickStreamer.jl consumer, collection contract checked
julia examples/telemetry_run.jl                                                # DeepSpaceTelemetry.jl consumer, collection contract checked
julia -e 'using Pkg; Pkg.activate("JuliaFormatter"; shared = true); Pkg.add("JuliaFormatter"); using JuliaFormatter; format(".")'   # formatting
```

Raw inputs are expected under `data/raw/` (gitignored); the configurations in
`configs/` reference them relative to the configuration file. A run writes a
collection directory `data/<collection id>/`: one distribution per threshold,
the prepared series with its gaps, and the provenance of every session. Its
`README.md` describes the files, and the
[Pipeline](https://PaulGoG.github.io/WaitingTimes.jl/stable/pipeline/) page
lists them. Rerunning with a wider threshold grid adds partitions and appends
a session, and an interrupted run resumes from the partitions already
written. Existing partitions are rewritten only when
`[output].overwrite = true`, and are backed up first.

`[input].source_descriptor` records with the collection the identity file of
the program that produced the input (a DeepSpaceTelemetry.jl run's
`descriptor.toml`, a MarketTickStreamer.jl session sidecar).
`[input].time_axis = "index"` places the series on the row ordinal of the
input instead of its clock; for a tick stream that is the trade count, and
exchange closures add no time to a wait. Both are described on the
[Configuration](https://PaulGoG.github.io/WaitingTimes.jl/stable/configuration/)
page.

Library use, in memory:

```julia
using WaitingTimes
s = QuantizedSeries(values, 4)                 # values::Vector{Union{Missing,Float64}}, 4 decimals
τ = waiting_times(s, 0.0005)                   # SegmentTreeSearch by default; 0 = no passage observed
τ == waiting_times(s, 0.0005, NaiveSearch())   # true for every kernel
d = empirical_distribution(τ, threshold(0.0005, s), s)
WaitingTimes.support(d), WaitingTimes.probabilities(d), WaitingTimes.cumulative(d)
```

From a collection on disk, and in real time:

```julia
c = load_collection("data/<collection id>")   # the REPL displays an overview; thresholds(c), summary_table(c)
source_descriptor(c)                           # the producer's descriptor of the input, verbatim, or nothing
WaitingTimes.source_summary(c)                 # its producer, version and code identity (git_tree_sha1)
class_counts(c, "0.0005")                      # exact and gap-crossing waits per support value
d = distribution(c, "0.0005")                  # one WaitingTimeDistribution
export_legacy(c, "outputData/<id>")           # WTS_<slug>_deltais<δ>.dat files of the 2024 analysis

est = OnlineWaitingTimes([0.5, 5.0], 2; time_unit = :nanosecond, late_policy = :skip)
push!(est, t_ns, price)                        # one sample; snapshot(est) gives the distributions so far
```

## Status

| Component | State |
|---|---|
| Kernels: naive (the reference), guarded, segment tree, Fenwick sweep, streaming | equal index by index in the test suite and checked there against exact first-passage laws; equal on the 7 124 thresholds of the six dataset configurations in the runs of 2026-09-26 (version 0.1.0) and 2026-11-25 (commit `8b506cb`) |
| Device kernel (KernelAbstractions extension) | CPU backend in the test suite; oneAPI on an Intel Arc GPU through the opt-in tests in `test/device/`; the CUDA, AMDGPU and Metal backends have not been run on a device |
| Gaps, classification, empirical distribution | in the test suite; the EUR-USD files of the 2024 generator are reproduced exactly |
| Online estimator (`OnlineWaitingTimes`) | equal to the batch result on every prefix of a record; memory bounded by a horizon |
| Pipeline: configuration, preprocessing, automatic `digits`, storage, provenance, resume | quickstart end to end in the tests; the published treatment of the Trieste series reproduces the files of the 2024 generator on the first two years of the record; writes provenance schema 4 and reads schemas 2 and 3 |
| Consumers of MarketTickStreamer.jl and DeepSpaceTelemetry.jl | `examples/`, run in CI against the pinned producer versions |
| Distributions.jl, CairoMakie and UnicodePlots extensions | in the test suite |

## Formulation

For a series `A₁..A_N` observed at strictly increasing integer times `t₁..t_N`
and a threshold `δ ≥ 0`, the waiting time of index `n` is

    τₙ = t_m − tₙ,   m = min{ m > n : A_m ≥ Aₙ + δ },

the elapsed time to the first observed value at least `δ` above `Aₙ`. Indices
without such an `m` are right-censored and contribute no waiting time.

Values and thresholds are quantised to a decimal grid with `digits` decimals
and handled as integers, so every kernel produces bit-identical results; the
naive forward scan (`NaiveSearch`) is the reference implementation the other
kernels are checked against. Time passes through missing samples
and data gaps; gaps are recorded and reported (`gap_table`, `classify`) and
never alter a waiting time.

`SegmentTreeSearch` is the default kernel, at milliseconds per threshold on
millions of points. `FenwickSweep` computes many thresholds in one sweep and
`StreamingSearch` runs online, for live pipelines. `GuardedSearch`, the naive
scan under a suffix-maximum guard and multithreaded, may stand in for
`NaiveSearch` as reference kernel where the naive scan is too slow
(`[algorithm].reference_kernel`). `DeviceSearch` runs the guarded scan on CPU
or GPU through the KernelAbstractions extension (`using KernelAbstractions`).

![How each kernel resolves the waiting times of one index on a 48-sample
series](docs/src/assets/kernels.gif)

On the full threshold grids of the six dataset configurations (7 124
thresholds, up to 10⁶ points), no kernel, the device kernel on the CPU
backend included, differed from the reference at a single index in the run of
2026-11-25 (commit `8b506cb`), as in the earlier run of 2026-09-26 (version
0.1.0).

![Wall time per threshold of every kernel on synthetic random walks of 10⁴
to 10⁶ points at three thresholds](docs/src/assets/timings.png)

## The transition across thresholds

![The survival function of the Geisenheim waiting times sweeping through the
threshold grid from 0 to 50 km/h](docs/src/assets/sweep.gif)

A collection holds one distribution per threshold. The indicators of the
2026 paper, the difference of the two fits' Kolmogorov–Smirnov distances and
the generalised Kullback–Leibler divergence between their tails, are
computed downstream from the collection along this sweep.

## How to cite

The package is described by `CITATION.cff`. In BibTeX:

```bibtex
@software{WaitingTimes.jl,
  author  = {Gogîță, Paul-Adrian},
  title   = {WaitingTimes.jl: exact waiting-time distributions of scalar time series},
  year    = {2026},
  version = {0.6.2},
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

The waiting time with a threshold is the investment horizon of I. Simonsen,
M. H. Jensen, A. Johansen, *Eur. Phys. J. B* **27**, 583 (2002),
[doi:10.1140/epjb/e2002-00193-x](https://doi.org/10.1140/epjb/e2002-00193-x),
which B. N. Vivirschi, P. C. Boboc, V. Băran, A. I. Nicolin, *Phys. Scr.*
**95**, 044011 (2020),
[doi:10.1088/1402-4896/ab623d](https://doi.org/10.1088/1402-4896/ab623d),
adapted to earthquake magnitudes; the full list of sources is on the
documentation's references page.

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
│   ├── Gaps.jl                   # gap detection, declaration with kinds, record structure, classification
│   ├── Describe.jl               # describe(s): summary of a series
│   ├── Kernels.jl                # NaiveSearch (reference kernel), GuardedSearch, scan_work
│   ├── SegmentTree.jl            # SegmentTreeSearch, the production kernel
│   ├── FenwickSweep.jl           # FenwickSweep, multi-threshold sweep
│   ├── Streaming.jl              # StreamingSearch, StreamingState, DistributionAccumulator
│   ├── Online.jl                 # OnlineWaitingTimes, online estimation at several thresholds
│   ├── Distribution.jl           # WaitingTimeDistribution, empirical_distribution
│   ├── Synthetic.jl              # synthetic series for tests and benchmarks
│   ├── Provenance.jl             # config overlays, canonical hashing, identifiers, fingerprints
│   ├── Config.jl                 # TOML schema, validated Settings, threshold grids
│   ├── Preprocessing.jl          # ingestion (csv/dat/arrow/tick), transforms, diagnostics
│   ├── Monitoring.jl             # terminal and file logging, TTY-gated progress
│   ├── Storage.jl                # per-threshold partitions, index, summary
│   ├── Orchestrator.jl           # prepare, generate (resume, reference checks), validate
│   ├── Backends.jl               # backend probes and selection (methods from the extensions)
│   ├── DeviceKernels.jl          # DeviceSearch, its workspace type, backend selection
│   └── precompile.jl             # PrecompileTools workload
├── ext/
│   ├── WaitingTimesDistributionsExt.jl   # DiscreteNonParametric view of a distribution
│   ├── WaitingTimesCairoMakieExt.jl      # figure theme, decade ticks, series and distribution figures
│   ├── WaitingTimesKernelAbstractionsExt.jl   # the device kernel on the CPU and GPU backends
│   ├── WaitingTimesUnicodePlotsExt.jl    # in-terminal overview of a series
│   └── WaitingTimes{CUDA,oneAPI,AMDGPU,Metal}Ext.jl   # GPU backend probes
├── scripts/
│   ├── Project.toml, activate.jl   # scripts environment (UnicodePlots for prepare.jl)
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
│   ├── preprocessing_tests.jl    # configuration and preprocessing tables, grid arithmetic, ignored-key warnings
│   ├── identity_tests.jl         # tree hash, manifest resolution, code identity
│   ├── structure_tests.jl        # gap kinds, record structure, time axes, partitions, round trip
│   ├── contract_tests.jl         # schema-2 read, dense files, limit guards, reference kernels, gap absorption
│   ├── device/                   # opt-in oneAPI tests on an Intel GPU (own environment)
│   └── fixtures/                 # EUR-USD and Trieste (1927–1928) inputs with outputs of the 2024 generator; README.md
│       ├── schema2/              # hand-written schema-2 collection
│       └── schema3/              # schema-3 collection written by 0.4.0
├── docs/
│   ├── Project.toml, activate.jl, make.jl, make_readme_assets.jl
│   └── src/                      # formulation, kernels, pipeline, configuration, provenance,
│       └── literate/             #   validation, interfacing, producers, API, internals, references; executable example
├── examples/                     # own environment: the two public packages from GitHub
│   ├── Project.toml, activate.jl, check_environment.jl
│   ├── tick_stream.jl            # MarketTickStreamer.jl: online against batch, session persistence and following, closures, both axes
│   └── telemetry_run.jl          # DeepSpaceTelemetry.jl run through its adapter → declared gaps → collections on both axes
├── .github/, codecov.yml         # CI (tests on Julia min, 1 and pre, producer examples, coverage, docs), Dependabot
└── CITATION.cff, CHANGELOG.md, LICENSE, .JuliaFormatter.toml, .gitattributes
```

</details>
