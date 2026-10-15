# Changelog

All notable changes to this project are documented here. The format follows
Keep a Changelog and the project adheres to Semantic Versioning.

## [0.3.1] - 2026-10-15

### Added

- `log_levels`, the level of every observation in per cent of one fixed
  reference, `100 log(x_k / x_ref)`, with `reference = "first"` (the first
  observed value) or a positive number. Values must be positive, missing
  observations stay missing, and the step records the reference, its value
  and the unit. A threshold on log levels is a move of a given share of the
  level while the path keeps its trends, unlike `trailing_mean_fluctuations`,
  whose reference moves with the series; the configuration page states the
  grid the one-step move needs.

### Changed

- The configuration page and the docstrings of `clip_quantile` and
  `clip_extremes` state one pruning rule: the published tables were computed
  with the 0.4 % rule of the 2024 code, and the 0.04 % stated in Rom. J.
  Phys. 69, 111 (2024), §2.3, is an omission of the paper. The shipped
  configurations are unchanged.

## [0.3.0] - 2026-10-14

### Added

- Gap kinds and sources. Every gap carries a kind (`detected`, `declared`,
  `hole`, `gap`, `session`; overlapping declarations join theirs with `+`)
  and the source it came from; `gaps.csv` has the columns `kind` and
  `source`. A gap found from the spacing of the time stamps that overlaps a
  declared interval is absorbed into it. Declared-gap files take a kind and a
  source per file or per `[[gaps]]` table; `declare_gaps` takes `kind` and
  `source` or named tuples.
- Record structure: `sampling_step`, `record_length` (grid positions in
  sampling steps), `observed_mask`, `segment_lengths` and `segment_table`;
  `segments.csv` in every collection and `record_length`, `n_observed`,
  `n_segments`, `sampling_step` in its metadata, so the erosion weight
  ``w(k) = \sum_s (L_s - k)_+`` needs no series. `record_length(c)` and
  `segment_lengths(c)` read them from a collection.
- `[input].time_axis = "index"`: the series on the row ordinal of the input
  (the payload row of a telemetry run, the trade count of a tick stream),
  rows with missing values kept as gaps, closures closed. `series.<ext>`
  keeps the row ordinal and the original clock of every observation, and
  `gaps_original.csv` the gaps of the original clock; `[series]` records the
  time axis and the time unit and epoch of the input's clock.
- Per-class counts in every partition, `count_exact` and
  `count_gap_crossing`, and the histogram of the lower bounds of the
  right-censored indices under `censoring/`; `class_counts(c, δ)` and
  `censoring_histogram(c, δ)` read them (`nothing` on schema-2 collections).
- Code identity of every session: `Provenance.source_identity` and
  `package_identity` (`git_tree_sha1`, `git_commit`, `git_dirty`,
  `repo_url`, `repo_rev`, `identity_source`) for a git checkout, a copy
  installed by Pkg and a bare directory, with `tree_hash`,
  `active_manifest` and `manifest_entry`. `metadata.toml` gains
  `[producer]` and `[environment]`, and every session a copy of the resolved
  manifest (`manifest_snapshot.toml`, `sessions/<id>.manifest.toml`).
- Normalised identity of a source descriptor, `source_summary` (in
  `[source]` of `metadata.toml` and as `source_summary(c)`): producer,
  version, `git_tree_sha1`, `git_dirty`, `git_commit`, whether an identity
  is present, and the version check against `MINIMUM_PRODUCER_VERSION`
  (DeepSpaceTelemetry.jl 2.5.0, MarketTickStreamer.jl 0.3.0).
- `describe(s)`, a summary of a series, and `plot_values(s)`, its value
  histogram, in the CairoMakie extension.
- `push!(est, missing)` advances a sample-indexed online estimator over a
  missing sample.
- `load_collection` validates the provenance schema and the time axis.
- The producer examples run in CI against the pinned producer versions and
  assert the collection contract; `tick_stream.jl` writes a MarketTickStreamer
  session sidecar and declares the exchange closures as session gaps.
- Public declarations of the read side, the series tools and the figure
  functions; the documentation states the public contract, including the
  field layout and constructors of `WaitingTimeDistribution`. A page on the
  producers.

### Changed

- Provenance schema `waitingtimes-provenance/3`. Collections of schema 2 are
  still read (time axis `elapsed`, gap kinds `unknown`).
- `QuantizedSeries` has the fields `gap_kinds` and `gap_sources`; its
  keyword constructor takes them (default kind `declared`), the positional
  inner constructor takes them after `gaps`. `gap_table` rows carry `kind` and
  `source`; `read_gap_intervals` returns named tuples with them.
- `Collection` has the field `time_axis`; `Settings` has `time_axis`.
- Preparation transforms return a new record instead of appending to their
  argument's (`with_step`); `record!` remains for explicit in-place use.
- Session identifiers carry the commit or tree hash of the code instead of
  the `git describe` string, which an installed copy did not have.
- With the Fenwick sweep the pipeline serves the thresholds of a session in
  one pass per batch, the batch bounded by `[limits].max_ram_gb`.
- The configurations `trieste_sea_level.toml` and `trustee_fuel.toml` carry a
  one-line description; the configuration page notes the pruned share stated
  in Rom. J. Phys. 69, 111 (2024), §2.3, against the rule of the code.

### Fixed

- `load_series` returned the series without its epoch, preparation record
  and value type; it now reproduces the stored series.
- The `offset = :auto` docstring of `trailing_mean_fluctuations` stated that
  the minimum is shifted to 1 in every case; the shift applies when the
  minimum is below 1.

## [0.2.1] - 2026-10-14

### Added

- `[input].source_descriptor` names a TOML file that identifies where the
  input came from (a producer's run, version, code and configuration). The
  collection keeps it byte for byte as `source.toml`, records its table and
  SHA-256 in the `[source]` section of `metadata.toml`, and includes the
  SHA-256 in the dataset identity; `source_descriptor(c)` returns the table
  of a loaded collection. Collections generated without one keep their
  identifiers.

### Changed

- `Settings` has a field `source_descriptor`, the absolute path of the
  configured descriptor or `""`; code that constructs `Settings` directly
  instead of through `load_settings` passes it.
- `examples/telemetry_run.jl` follows DeepSpaceTelemetry.jl 2.6: the
  scenario runs on the tick clock, the series is placed on the payload grid,
  the holes of `masks/gaps.csv` are its declared gaps (counted by cause and
  checked against the gaps found from the sample spacing, and against the
  settled `holes.csv` feed), and the collection carries the run's
  `descriptor.toml` as its source, whose producer identity (source tree hash,
  commit, dirty flag) it reports. The examples environment pins
  DeepSpaceTelemetry.jl 2.6.2 and MarketTickStreamer.jl 0.3.0, both on
  CSV.jl 1.1, and reads JSON with JSON.jl.

### Fixed

- A relative `--out` of `examples/telemetry_run.jl` was resolved against the
  temporary configuration directory instead of the working directory.
- The Distributions extension defined its `DiscreteNonParametric` method
  through an unqualified name, which Julia 1.12 and later deprecate.

## [0.2.0] - 2026-10-01

### Added

- Bounded memory for online evaluation. `StreamingState` and
  `OnlineWaitingTimes` accept `upper_bound`, the largest attainable value:
  indices whose target lies above it are counted as censored on arrival
  instead of being stored, with unchanged results; `bound_policy` (`:error`
  or `:skip`) governs a value above the bound. `horizon` evicts indices
  pending longer than it as censored, bounding the heap by twice the samples
  within one horizon; `status` reports evicted and unreachable indices.
- `WaitingTimeDistribution` carries the `horizon` at which it is censored;
  `empirical_distribution(τ, δ, s; horizon)` gives the batch counterpart of
  an online snapshot under a horizon.
- `digits = "auto"` in `[quantization]`, with `auto_max_digits`,
  `auto_tolerance` and `auto_step_ratio`: values on a decimal grid take their
  recorded resolution, other values the smallest grid that places the
  thresholds, keeps the step below a fraction of the increment scale, and
  leaves the δ = 0 distribution unchanged to within a Kolmogorov–Smirnov
  tolerance when one more decimal is kept. The choice is recorded in the
  preparation record. `suggest_digits`, `digits_sensitivity` and
  `increment_scale` expose the rule; `scripts/prepare.jl --digits-scan`
  prints the sensitivity table.
- `WaitingTimes.ks_distance`, the exact two-sample Kolmogorov–Smirnov
  distance between two waiting-time distributions.

### Changed

- `WaitingTimeDistribution` has a twelfth field, `horizon` (`nothing`
  without one), included in equality and hashing; the eleven-argument
  constructor remains.
- `Settings.digits` is `nothing` under `digits = "auto"`; the resolved value
  is the `digits` of the prepared series.
- The test matrix includes the minimum supported Julia version (1.12).

### Fixed

- The documentation described `FenwickSweep` as parallel over thresholds;
  the sweep is sequential.

## [0.1.1] - 2026-09-30

### Changed

- CSV.jl 1.1 is supported alongside 0.10. Time columns are read as text and
  converted by the package, so time stamps do not depend on the date-time
  inference of the installed CSV version; the six dataset configurations
  prepare identical series under both versions.
- Tables read from a collection (`summary_table`, partitions, series files)
  hold plain `String` text columns without pooling under both CSV versions.

### Fixed

- A `time_format` made only of digits (`yyyymmdd`) is honoured; such stamps
  were previously read as integers in `epoch_unit`.
- ISO 8601 time stamps keep fractions finer than a millisecond (up to
  nanoseconds) instead of failing to parse; integral numbers written with a
  decimal point are accepted as epoch stamps.

## [0.1.0] - 2026-09-26

First release. Everything below is new.

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
  configurations state the published treatment.
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
- Precompile workload (PrecompileTools) over the kernels, the distribution,
  the online estimator and a small pipeline run: the first waiting-time call
  after loading drops from 0.7 s to below 0.1 s and the first configuration
  load with preparation from 7 s to below 1 s.
- Documentation site (formulation, kernels, pipeline, configuration,
  provenance, validation, interfacing, an executable downstream example,
  API, references).
- Test suite: static QA (Aqua, JET, ExplicitImports), unit and invariant
  tests, kernel equivalence on synthetic series, exact regression against
  legacy EUR-USD outputs; every kernel verified against the reference kernel
  on every threshold of every dataset configuration.
