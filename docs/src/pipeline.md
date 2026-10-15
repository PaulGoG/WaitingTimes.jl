# Pipeline

A run is driven by one TOML file ([Configuration](@ref)) and proceeds in
three stages.

## Prepare

[`prepare`](@ref) reads the input (CSV, DAT, Arrow or MarketTickStreamer
tick files) with the configured value and time columns, applies the
preprocessing steps in order (range selection, surgical cuts, trailing-mean
fluctuations in percent, log returns, log levels, differences, centred moving-average
detrending, quantile clipping, tie collapsing), quantises to the grid,
attaches detected and declared gaps with their kinds ([Gap kinds](@ref)), and
places the series on the configured [Time axis](@ref). Every step returns a
new `PreparationRecord` with the step appended. `scripts/prepare.jl` prints sampling and value
diagnostics, the gap table longest first, and an in-terminal overview, so
large gaps can be located and cut before a run.

## Generate

[`generate`](@ref) computes every configured threshold not yet present in the
collection, writes one partition per threshold, runs reference checks, and
records the session. With the Fenwick sweep the thresholds of a session are
served in one pass per batch, the batch as large as `[limits].max_ram_gb`
leaves room for. The collection directory (provenance schema
`waitingtimes-provenance/3`) is

```
data/<collection id>/
├── config.toml                 effective configuration of the first session
├── metadata.toml               identity, series, dataset, source, producer, environment, sessions
├── source.toml                 the source descriptor of the input, when configured
├── manifest_snapshot.toml      resolved manifest of the latest session
├── hardware.txt                fingerprint of the latest session
├── sessions/<id>.toml          per-session record: kernel, backend, code identity, timings, reference checks
├── sessions/<id>.config.toml   effective configuration of that session
├── sessions/<id>.manifest.toml resolved manifest of that session
├── series.<csv|arrow>          values, times, row, time_original
├── series.toml                 description of the series and its preparation record
├── gaps.csv                    start, stop, kind, source
├── segments.csv                start, stop, length, kind_before, kind_after
├── gaps_original.csv           gaps of the original clock (index axis only)
├── distributions/delta=<fixed>.<csv|arrow>   tau, count, pmf, cdf, ccdf, count_exact, count_gap_crossing
├── censoring/delta=<fixed>.<csv|arrow>       lower, count
├── waiting_times/              optional dense waiting-time vectors with classes and bounds
├── index.toml                  partitions with checksums and per-threshold statistics
├── summary.csv                 one row per threshold
├── catalog.csv                 every artefact with its descriptor columns
└── run.log
```

In `:elapsed` mode `count_exact + count_gap_crossing = count` at every
support value; in `:exact` mode the distribution holds exact waits only and
`count_gap_crossing` is zero. The censoring histogram counts the
right-censored indices by the lower bound of their waiting time (the elapsed
time to the last observation before the first gap, or to the end of the
record), which with the class counts is what an estimator for censored data
needs. The dense files `waiting_times/delta=<δ>` (`[output].store_waiting_times
= true`) hold one row per index (`tau`, `class`, `lower`, `upper`): about
25 bytes per index and threshold in Arrow and 30 to 40 in CSV, so a series of
10⁶ points over a grid of 1000 thresholds writes some 25 to 40 GB; they are
needed only for statistics of individual indices.

Rerunning with a wider threshold grid adds partitions and appends a session;
existing partitions are skipped unless `[output].overwrite = true`, in which
case they are backed up as `<name>#k.<ext>` first.

## Validate

[`validate`](@ref) compares the configured kernel with the reference kernel on chosen
thresholds and reports equality, the number of differing indices and the
reference kernel's cost. `scripts/validate.jl` exits non-zero on any disagreement.

## Scripts

```
julia --threads=auto scripts/run_pipeline.jl --config configs/geisenheim_wind.toml
julia scripts/launch_run.jl --config configs/geisenheim_wind.toml
julia scripts/prepare.jl --config configs/geisenheim_wind.toml
julia --threads=auto scripts/validate.jl --config configs/quickstart.toml --deltas 0.001,0.005
julia --threads=auto scripts/crosscheck.jl --config configs/quickstart.toml
julia scripts/lineage.jl data/<collection id>
```

Every script activates the package environment itself. `launch_run.jl`
starts the pipeline as a detached process with a console log under
`data/logs/`. `run_pipeline.jl` loads the GPU package named by
`[algorithm].backend` when it is installed, which activates the corresponding
extension. `crosscheck.jl` compares every kernel with the naive reference
kernel index by index on the whole threshold grid of a configuration.
