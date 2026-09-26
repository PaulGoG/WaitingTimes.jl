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
  { op = "clip_quantile", q = 0.9996, splice = true },
]

[gaps]
declared = ""                     # TOML with intervals = [[start, stop], ...]; "" = none
detect = "cadence"                # "none" | "cadence" | "threshold"
cadence = 1                       # >= 1
threshold = 0                     # > 0 in time units when detect = "threshold"
mode = "elapsed"                  # "elapsed" | "exact"

[quantization]
digits = 1                        # 0:15

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
| `clip_quantile` | `q`, `splice = true` | prune the observations with magnitude above the `q` quantile of the magnitudes (`q = 0.9996`: the extreme 0.04 % of both signs, as in the papers) |
| `clip_sigma` | `k = 3`, `center = "mean"`, `scale = "std"`, `splice = true` | prune the observations farther than `k` scale units from the centre; `"median"` with `"mad"` is the robust pair |
| `collapse_ties` | `policy` | resolve equal time stamps (`"error"`, `"first"`, `"last"`, `"mean"`) |

Pruning deletes rows: with `splice = true` (the default) the removed
observation's slot vanishes and the clock closes over it, as in the original
analysis, because a pruned value is an anomaly that should not have happened;
`splice = false` keeps the slot as a recorded gap instead. After every step
the observed values must be finite; a non-finite value aborts the run naming
the step and the row.

The published treatment of the Trieste series is the sequence shown above:
`round` to the grid, percentage fluctuations from a 708-hour (lunar month)
trailing mean with the automatic shift, pruning of the extreme 0.04 %. The
2024 code pruned 0.4 % in integer-valued batches; `q = 0.996` approximates
that variant.

Thresholds are generated on the grid: a linear grid from `min` to `max` by
`step`; a logarithmic grid with `points_per_decade` between `min > 0` and
`max`, snapped to the grid and de-duplicated; or the explicit `values`.
[`threshold_list`](@ref) returns them sorted and distinct.

## Dataset descriptors

`configs/datasets/<slug>.toml` records the source, retrieval date, licence,
citation, quantity, unit, sampling and SHA-256 of a raw file. When
`[input].dataset` names one, the checksum is verified before the run and the
descriptor is copied into the collection's metadata.
