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
- Test suite: static QA (Aqua, JET, ExplicitImports), unit and invariant
  tests, kernel equivalence on synthetic series, exact regression against
  legacy EUR-USD outputs.
