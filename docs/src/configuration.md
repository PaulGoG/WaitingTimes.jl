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
value_column = 9                  # column name or 1-based index
time_column = ""                  # column name or index; "" = sample index
time_unit = "sample"              # "sample" | "nanosecond" | "microsecond" | "millisecond" | "second" | "minute" | "hour" | "day"
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
declared = ""                     # TOML with intervals = [[start, stop], ...]; "" = none
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
store_waiting_times = false
overwrite = false

[run]
seed = 12345
log_level = "info"                # "debug" | "info" | "warn"
```

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
| `differences` | | `x_k - x_{k-1}` |
| `centered_moving_average` | `window` (odd) | subtract the centred moving average |
| `clip_quantile` | `q`, `splice = false` | prune the observations with magnitude above the `q` quantile of the magnitudes (`q = 0.9996`: the extreme 0.04 % of both signs, as in the papers) |
| `clip_extremes` | `fraction = 0.004`, `digits`, `splice = false` | the pruning loop of the 2024 code: remove whole magnitude levels from the top until at most `1 - fraction` of the rows remain |
| `clip_sigma` | `k = 3`, `center = "mean"`, `scale = "std"`, `splice = false` | prune the observations farther than `k` scale units from the centre; `"median"` with `"mad"` is the robust pair |
| `collapse_ties` | `policy` | resolve equal time stamps (`"error"`, `"first"`, `"last"`, `"mean"`) |

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

Thresholds are generated on the grid: a linear grid from `min` to `max` by
`step`; a logarithmic grid with `points_per_decade` between `min > 0` and
`max`, snapped to the grid and de-duplicated; or the explicit `values`.
[`threshold_list`](@ref) returns them sorted and distinct.

## Dataset descriptors

`configs/datasets/<slug>.toml` records the source, retrieval date, licence,
citation, quantity, unit, sampling and SHA-256 of a raw file. When
`[input].dataset` names one, the checksum is verified before the run and the
descriptor is copied into the collection's metadata.
