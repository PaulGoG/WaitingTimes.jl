# Configuration

One TOML file per run, parsed and validated by [`load_settings`](@ref) into
an immutable [`Settings`](@ref). Relative paths resolve against the file's
directory. A top-level `base_config = "file.toml"` merges the file onto a
base (one level), so dataset files can share defaults with
`configs/quickstart.toml`. Unknown keys produce warnings; unusable values
raise errors naming the key.

```toml
[input]
path = "../data/raw/meteostatGeisenheim.csv"   # relative to this file unless absolute
format = "csv"                    # one of: "csv" | "dat" | "arrow" | "tick"
dataset = "geisenheim-wind_speed" # descriptor in configs/datasets/, or ""
source_descriptor = ""            # TOML identity of the data's origin (e.g. a producer run), or ""
value_column = 9                  # column name or 1-based index
time_column = ""                  # column name or index; "" = sample index
time_unit = "sample"              # "sample" | "nanosecond" | "microsecond" | "millisecond" | "second" | "minute" | "hour" | "day"
time_axis = "elapsed"             # "elapsed" | "index"
time_format = ""                  # Dates format for textual stamps; "" = ISO 8601 or numeric
epoch_unit = "second"             # unit of numeric stamps in the file
delimiter = ""                    # "" = format default
header = false                    # first row is a header
missing_policy = "drop"           # "drop" | "error"
tie_policy = "error"              # "error" | "first" | "last" | "mean"
quantity_label = "wind speed"     # plots only
unit_label = "km/h"               # plots only

[preprocessing]
steps = [                         # applied in order; see Preprocessing steps below
  { op = "round", digits = 1 },
  { op = "trailing_mean_fluctuations", window = 708, denominator = "mean", offset = "auto" },
  { op = "clip_extremes", fraction = 0.004, digits = 1 },
]

[gaps]
declared = ""                     # TOML of declared gaps (intervals and/or [[gaps]] tables); "" = none
detect = "cadence"                # "none" | "cadence" | "threshold"
cadence = 1                       # >= 1
threshold = 0                     # > 0 in time units when detect = "threshold"
mode = "elapsed"                  # "elapsed" | "exact"

[quantization]
digits = 1                        # 0:15, or "auto"
auto_max_digits = 8               # 0:14; largest automatic choice
auto_tolerance = 1e-3             # (0, 1); Kolmogorov-Smirnov tolerance of the automatic choice
auto_step_ratio = 0.1             # (0, 1]; largest grid step over the increment scale

[thresholds]
mode = "linear"                   # "linear" | "log" | "explicit"
min = 0.0                         # >= 0, on the grid
max = 50.0                        # > min, on the grid
step = 0.1                        # > 0, on the grid (linear)
points_per_decade = 10            # >= 1 (log)
values = []                       # explicit list, on the grid

[algorithm]
search = "segment_tree"           # "naive" | "guarded" | "segment_tree" | "fenwick_sweep" | "streaming" | "device"
backend = "none"                  # "none" | "auto" | "cuda" | "oneapi" | "amdgpu" | "metal"
chunk_size = 4096                 # >= 1
reference_checks = 2              # >= 0; thresholds recomputed with the reference kernel
reference_kernel = "naive"        # "naive" | "guarded" | "device"

[limits]
max_ram_gb = 16.0                 # >= 0
max_vram_gb = 8.0                 # >= 0
max_reference_work = 1e12         # >= 0; element comparisons of one reference check

[output]
root = "../data"                  # collections under root/<collection id>
format = "arrow"                  # "csv" | "arrow"
store_waiting_times = false       # write waiting_times/delta=<δ> (one row per index)
overwrite = false

[run]
seed = 12345
log_level = "info"                # "debug" | "info" | "warn"
```

## Time axis

`time_axis = "elapsed"` (the default) keeps the clock of the input: the time
column in `time_unit`, or the sample index when there is none, and waiting
times are elapsed times on that clock, closures and outages included. With
`time_axis = "index"` the series is placed on the row ordinal of the
prepared input: observation `k` at the position of its row, counted from the
first observed row. A row whose value is missing keeps its ordinal and stays
a gap, whereas a stretch of the clock that holds no row at all (a market
closure, a timestamp gap of an event stream) closes, so a wait across it is
shorter by its length. For the three kinds of input this is

| Input | `elapsed` | `index` |
|---|---|---|
| sampled file | the time column, or the row | the row of the file |
| MarketTickStreamer.jl ticks | exchange time at the stream's resolution | the trade count |
| DeepSpaceTelemetry.jl payload | mission time on the payload grid | the payload row, when the hole rows are written as missing values (`examples/telemetry_run.jl`) |

The original clock is kept: `series.<ext>` carries the row ordinal (`row`)
and the original time (`time_original`) of every observation, so the
collection can be rebuilt on the other axis, and on the index axis the gaps
of the original clock are written to `gaps_original.csv`. The time axis
enters the series identity only when it is `index`, so elapsed collections
keep their identifiers.

## Gap kinds

Every gap carries a kind and a source. Gaps detected from the spacing of
the time stamps (`detect`) are `detected`, with the input file as source.
Gaps declared in the `[gaps].declared` file take the kind and source given
there:

```toml
kind = "gap"                      # default kind of the intervals: "declared" | "hole" | "gap" | "session"
source = "masks/gaps.csv"         # default source; the file's name when absent
intervals = [[0, 600000], [7200000, 9600000]]   # [start, stop) in the series' time unit

[[gaps]]                          # or one table per gap, with its own kind and source
start = 151200000
stop = 153000000
kind = "session"
source = "exchange calendar"
```

`hole` and `gap` name the declared-hole feed (`holes.csv`) and the gap
table (`masks/gaps.csv`) of a DeepSpaceTelemetry.jl run, `session` a session
calendar or an exchange closure, `declared` any other declaration. A
detected gap that overlaps declared ones is absorbed into them (they keep
their kind and extend to cover it), so a producer's hole is one gap of the
producer's kind. Declarations of one kind that overlap or touch merge;
touching declarations of different kinds stay separate gaps; overlapping
ones of different kinds merge, with the kinds joined by `+` (`session+hole`).
A declared interval must lie inside the record and contain no observation.

## Choosing `digits`

Values are quantised to ``q_n = \mathrm{round}(x_n \cdot 10^d)`` and
thresholds to ``\delta \cdot 10^d``. The grid step ``w = 10^{-d}`` decides
which observations count as equal (the ties, and with them the ``\delta = 0``
distribution), resolves the threshold grid, and bounds the rounding error by
``w/2``. A grid finer than the data's own resolution changes nothing but the
size of the integers; a coarser one merges observations. `digits = "auto"`
applies these rules after the preprocessing steps:

1. Values on a decimal grid (as recorded, rounded, or differenced) take their
   recorded resolution, [`resolution_digits`](@ref
   WaitingTimes.Preprocessing.resolution_digits), raised to the decimals the
   threshold grid needs.
2. Other values (fluctuations, returns, detrended series) take the smallest
   ``d`` that places the threshold grid, keeps ``w`` at most
   `auto_step_ratio` times the increment scale (the median absolute
   difference of consecutive values, so that the rounding variance
   ``w^2/12`` is negligible against the increments), and changes the
   ``\delta = 0`` distribution by less than `auto_tolerance` in
   Kolmogorov–Smirnov distance when one more decimal is kept.

The choice, the rule that decided it and the distance are recorded in the
preparation record of the series and logged; a configuration whose tolerance
is met at no grid up to `auto_max_digits` fails. `julia scripts/prepare.jl
--config PATH --digits-scan` prints the sensitivity table
([`digits_sensitivity`](@ref WaitingTimes.Preprocessing.digits_sensitivity))
from which a fixed value can also be read. For recorded series whose last
digit is instrument noise the table shows whether a coarser grid leaves the
distributions unchanged; that coarsening is left to the analyst.
The rationale follows the statistical theory of quantisation (Widrow, Kollár
and Liu) and the rounding of statistics to measurement precision (Cousineau),
see [References](@ref).

## Preprocessing steps

Each entry of `steps` is a table with an `op` key; parameters are validated
when the configuration is loaded.

| `op` | Parameters | Effect |
|---|---|---|
| `select_range` | `from`, `to` | keep the rows with time (or index) in `[from, to]` |
| `exclude_intervals` | `intervals = [[a, b], ...]`, `splice = true` | remove the rows in `[a, b)`; with `splice` the time axis closes over the cut, otherwise the rows become missing (a recorded gap) |
| `round` | `digits` | round the values to `digits` decimals (the original analysis rounded before detrending) |
| `trailing_mean_fluctuations` | `window`, `denominator = "mean"`, `offset = "none"`, `on_nonpositive = "error"` | deviation from the mean of the previous `window` observations: `"mean"` is the percentage fluctuation of the papers, `"scale"` divides by the standard deviation of the deviations, `"none"` keeps data units; `offset = "auto"` shifts the series so that its minimum is 1 before a `"mean"` computation (the papers' rule), a number is added as given; `on_nonpositive = "missing"` records a non-positive trailing mean as a missing observation instead of aborting |
| `log_returns` | | `100 log(x_k / x_{k-1})` |
| `log_levels` | `reference = "first"` | `100 log(x_k / x_ref)`, the level in per cent of the first observed value or of a positive number; values must be positive, missing observations stay missing |
| `differences` | | `x_k - x_{k-1}` |
| `centered_moving_average` | `window` (odd) | subtract the centred moving average |
| `clip_quantile` | `q`, `splice = false` | prune the observations with magnitude above the `q` quantile of the magnitudes (`q = 0.9996`: the extreme 0.04 % of both signs, as in the papers) |
| `clip_extremes` | `fraction = 0.004`, `digits`, `splice = false` | the pruning loop of the 2024 code: remove whole magnitude levels from the top until at most `1 - fraction` of the rows remain |
| `clip_sigma` | `k = 3`, `center = "mean"`, `scale = "std"`, `splice = false` | prune the observations farther than `k` scale units from the centre; `"median"` with `"mad"` is the robust pair |
| `collapse_ties` | `policy` | resolve equal time stamps (`"error"`, `"first"`, `"last"`, `"mean"`) |

`log_levels` keeps the price path and its trends, so a threshold is a move
of a given share of the level, whereas the reference of
`trailing_mean_fluctuations` moves with the series. The grid must then
resolve the typical one-step move, about 0.03 % between consecutive BTC
minute closes: three to four decimals, or `digits = "auto"`.

Pruning discards a measurement as invalid. With `splice = false` (the
default) the value becomes missing and its slot remains, so the time passed
and the cut is a recorded gap; this is what the 2024 code did, whose time
column kept the original row indices, and what reproduces the published
results. With `splice = true` the row and its slot are deleted and the clock
closes over it. After every step the observed values must be finite; a
non-finite value aborts the run naming the step and the row.

The published treatment of the Trieste series is `round` to the grid,
percentage fluctuations from a 708-hour (lunar month) trailing mean with the
automatic shift, and `clip_extremes` with `fraction = 0.004`: the paper
states the pruning as 0.04 % of both signs (`clip_quantile` with
`q = 0.9996` applies that literally), but the 2024 code that produced the
published tables pruned 0.4 % in whole magnitude levels, and only that rule
reproduces Table 1 of the paper for the Trieste and fuel-consumption series.
The shipped `trieste_sea_level.toml` and `trustee_fuel.toml` state it.

The two rules differ by a factor of ten in the pruned share: Rom. J. Phys.
69, 111 (2024), §2.3
([doi:10.59277/RomJPhys.2024.69.111](https://doi.org/10.59277/RomJPhys.2024.69.111)),
states 0.04 %, whereas `trieste_sea_level.toml` keeps the `fraction = 0.004`
of the code. A configuration that wants the stated share replaces the step by
`{ op = "clip_quantile", q = 0.9996 }`.

Thresholds are generated on the grid: a linear grid from `min` to `max` by
`step`; a logarithmic grid with `points_per_decade` between `min > 0` and
`max`, snapped to the grid and de-duplicated; or the explicit `values`.
[`threshold_list`](@ref) returns them sorted and distinct.

## Dataset descriptors

`configs/datasets/<slug>.toml` records the source, retrieval date, licence,
citation, quantity, unit, sampling and SHA-256 of a raw file. When
`[input].dataset` names one, the checksum is verified before the run and the
descriptor is copied into the collection's metadata.

## Source descriptors

A dataset descriptor describes a raw file; a source descriptor identifies
where the data of a run came from when they were produced by another
program, so that every distribution of the collection traces to that
producer's run, version, code and configuration.
`[input].source_descriptor` names any TOML file, by a path relative to the
configuration or absolute; it must exist and parse. The file is recorded,
not interpreted: it is copied byte for byte to `source.toml` in the
collection directory, its table and SHA-256 are written to the `[source]`
section of `metadata.toml`, and the SHA-256 enters the dataset identity, so
that the same input from another source run is another collection.
[`source_descriptor`](@ref) returns the table from a loaded collection.

Beside the verbatim table, `[source]` holds a summary in the same keys for
every producer ([`source_summary`](@ref WaitingTimes.Provenance.source_summary)):
`producer`, `producer_version`, `git_tree_sha1`, `git_dirty`, `git_commit`,
`identity` (whether `git_tree_sha1` is present), and the check of the
producer's version against the oldest one whose file contract this version
reads (`producer_compat`, `compat_checked`, `compat_satisfied`;
[`MINIMUM_PRODUCER_VERSION`](@ref WaitingTimes.Provenance.MINIMUM_PRODUCER_VERSION):
DeepSpaceTelemetry.jl 2.5.0, MarketTickStreamer.jl 0.3.0). A version below
the minimum is recorded with a warning; a descriptor without `git_tree_sha1`
is recorded as having no code identity, never rejected.

The first producer to write one is DeepSpaceTelemetry.jl (2.5 and later):
`descriptor.toml` at the root of a finished run directory, schema
`deepspacetelemetry-run/1`, with the run identifier, the producer's version,
the identity of its code, the configuration hash, the clock mode, the seed,
the payload geometry and the size and SHA-256 of every table of the run
(`examples/telemetry_run.jl`). MarketTickStreamer.jl writes a session
sidecar, `<session>.meta.toml`, with the session, the producer's version,
commit and dirty flag, the hardware and the configuration
(`examples/tick_stream.jl`); it records no tree hash. The authoritative key of the producer's code
is `git_tree_sha1` with `git_dirty = false`; `git_commit` is filled when the
producer ran from a checkout or was pinned by a full commit hash, and adds
the history. Both are recorded since DeepSpaceTelemetry 2.6.1, also for a
copy installed by Pkg; in a descriptor written before, a missing key means
unknown and `git_commit` of an installed copy is empty.
