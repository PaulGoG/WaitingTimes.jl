# Changelog

All notable changes to this project are documented here. The format follows
Keep a Changelog and the project adheres to Semantic Versioning.

## [Unreleased]

### Added

- Decimal integer grid (`quantize`, `Threshold`, `format_threshold`,
  `parse_threshold`): values and thresholds handled as integers with exactly
  `digits` decimals.
- `QuantizedSeries` with explicit time axis, recorded gaps and a
  `PreparationRecord`; construction from raw values with `missing` keeps time
  positions.
- Gap detection by cadence, declaration of external gap intervals,
  classification of waiting times (exact, gap-crossing, right-censored) with
  bounds.
- `NaiveSearch`, the reference kernel, and `GuardedSearch` (suffix-maximum
  censoring proof), multithreaded with chunked dynamic scheduling;
  `scan_work`, the cost model of a reference check in element comparisons.
- `WaitingTimeDistribution` and `empirical_distribution` with class accounting
  and elapsed or exact mode.
- `SegmentTreeSearch` (production kernel, `O(log N)` per index, parallel),
  `FenwickSweep` (one sweep for many thresholds) and `StreamingSearch` with
  `StreamingState`, `update!` and `DistributionAccumulator` for online
  evaluation; all bit-identical to the reference kernel.
- `Synthetic` module: random walks with drift, trend, cycles, noise, jumps
  and heavy tails, independent samples, missing runs, irregular time stamps,
  and gap generators modelled on a duty-cycled telemetry link (contact-window
  duty cycle, Bernoulli and Gilbert-Elliott packet loss with the analytic
  stationary loss rate, scheduled disruptions with blackout and linear
  recovery, `gap_scenario` composing them).
- `bench/` environment with kernel benchmarks and exact cross-checks.
- Preprocessing after the published treatment, configurable: a `round` step;
  `trailing_mean_fluctuations` with `denominator` (`"mean"`, the percentage
  fluctuation of the papers; `"scale"`; `"none"`), `offset` (`"auto"`, the
  papers' shift to a minimum of 1, or a number) and `on_nonpositive`
  (`"error"` or `"missing"`); pruning by `clip_quantile`, the new `clip_sigma`
  (`k`, `center`, `scale`) and `clip_extremes` (the pruning loop of the 2024
  code), which discard the value and keep its slot as a recorded gap
  (`splice = false`, the published semantics) or delete the slot
  (`splice = true`); a finite-value check after every step; step parameters
  validated when the configuration loads. The Trieste and fuel-consumption
  configurations state the published treatment and reproduce Table 1.
- `OnlineWaitingTimes`: online estimation at several thresholds from raw
  `(time, value)` samples, with `snapshot`, `status`, `pending`, a late-sample
  policy and bounded memory, for live pipelines.
- Collection read side: `Collection`, `load_collection`, `list_collections`,
  `distribution`, `thresholds`, `summary_table`, `load_series`, and
  `export_legacy`, which writes the `WTS_<slug>_deltais<δ>.dat` tables of the
  2024 analysis bit for bit; every collection directory carries a generated
  `README.md`. The cumulative distribution is computed from the integer
  counts, so it is exact.
- Pipeline: validated TOML configuration with overlays (`Config`), identity
  hashing, git and hardware fingerprints and metadata files (`Provenance`),
  self-describing file names (`Naming`), ingestion of CSV, DAT, Arrow and
  tick files with recorded transformations and diagnostics (`Preprocessing`),
  per-threshold partitions with index, summary and catalogue (`Storage`),
  and generation with resume, session records with per-session configuration
  snapshots, and reference checks bounded by `scan_work` (`Orchestrator`);
  scripts for running, launching, preparing, validating, cross-checking and
  tracing lineage; example configurations and dataset descriptors.
- Extensions: `discrete_distribution` (Distributions.jl); `figure_theme`,
  `decade_ticks`, `plot_series`, `plot_distribution` and `save_figure`
  (CairoMakie) following one publication theme.
- `DeviceSearch`: the naive scan as a KernelAbstractions kernel with a backend
  registry (`Backends`) filled by the CUDA, oneAPI, AMDGPU and Metal
  extensions; a named backend that is unavailable is an error, `:auto` falls
  back to the CPU; CPU backend in the default tests, opt-in device tests
  under `test/device/`.
- Documentation site (formulation, kernels, pipeline, configuration,
  provenance, validation, interfacing, an executable downstream example,
  API, references).
- Test suite: static QA (Aqua, JET, ExplicitImports), unit and invariant
  tests, kernel equivalence on synthetic series, exact regression against
  legacy EUR-USD outputs; every kernel verified against the reference kernel
  on every threshold of every dataset configuration.
