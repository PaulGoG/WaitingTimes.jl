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
- `NaiveSearch` oracle and `GuardedSearch` (suffix-maximum censoring proof),
  multithreaded with chunked dynamic scheduling.
- `WaitingTimeDistribution` and `empirical_distribution` with class accounting
  and elapsed or exact mode.
- `SegmentTreeSearch` (production kernel, `O(log N)` per index, parallel),
  `FenwickSweep` (one sweep for many thresholds) and `StreamingSearch` with
  `StreamingState`, `update!` and `DistributionAccumulator` for online
  evaluation; all bit-identical to the oracle.
- `Synthetic` module: random walks with drift, trend, cycles, noise, jumps
  and heavy tails, independent samples, missing runs, irregular time stamps.
- `bench/` environment with kernel benchmarks and exact cross-checks.
- Pipeline: validated TOML configuration with overlays (`Config`), identity
  hashing, git and hardware fingerprints and metadata files (`Provenance`),
  self-describing file names (`Naming`), ingestion of CSV, DAT, Arrow and
  tick files with recorded transformations and diagnostics (`Preprocessing`),
  per-threshold partitions with index, summary and catalogue (`Storage`),
  and generation with resume, session records and oracle checks
  (`Orchestrator`); scripts for running, launching, preparing, validating and
  tracing lineage; example configurations and dataset descriptors.
- Extensions: `discrete_distribution` (Distributions.jl) and `plot_series`,
  `plot_distribution`, `save_figure` (CairoMakie).
- `DeviceSearch`: the naive scan as a KernelAbstractions kernel with a backend
  registry (`Backends`) filled by the CUDA, oneAPI, AMDGPU and Metal
  extensions; CPU backend in the default tests, opt-in device tests under
  `test/device/`.
- Documentation site (formulation, kernels, pipeline, configuration,
  provenance, validation, interfacing, an executable downstream example,
  API, references).
- `scripts/crosscheck.jl`: index-by-index comparison of every kernel on a
  configured series, with the GPU kernel when a backend is loaded.
- Test suite: static QA (Aqua, JET, ExplicitImports), unit and invariant
  tests, kernel equivalence on synthetic series, exact regression against
  legacy EUR-USD outputs.
