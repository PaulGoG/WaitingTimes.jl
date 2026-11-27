# Pipeline

A run is driven by one TOML file ([Configuration](@ref)): it prepares the
series, then generates the distributions; validation is a separate check on
the same configuration.

## Prepare

[`prepare`](@ref) reads the input (CSV, DAT, Arrow or MarketTickStreamer
tick files) with the configured value and time columns and applies the
preprocessing steps in order ([Preprocessing steps](@ref)); each returns a
new `PreparationRecord` with the step appended. The values are then
quantised to the grid, detected and declared gaps attached with their kinds
([Gap kinds](@ref)), and the series placed on the configured
[Time axis](@ref). `scripts/prepare.jl` prints sampling and value
diagnostics, the gap table longest first, and an in-terminal overview, so
large gaps can be located and cut before a run.

## Generate

[`generate`](@ref) computes every configured threshold not yet present in the
collection, writes one partition per threshold, runs reference checks, and
records the session. With the Fenwick sweep a session's thresholds are
computed in one pass per batch, the batch as large as `[limits].max_ram_gb`
leaves room for. The collection directory (provenance schema
`waitingtimes-provenance/4`) is

```
data/<collection id>/
├── README.md                   what the collection is and how to load it, rewritten by every session
├── config.toml                 effective configuration of the first session
├── metadata.toml               identity, series, dataset, source, producer, environment, sessions
├── source.toml                 the source descriptor of the input, when configured
├── manifest_snapshot.toml      resolved manifest of the latest session
├── hardware.txt                fingerprint of the latest session
├── sessions/<id>.toml          per-session record: kernel, backend, code identity, timings, reference checks
├── sessions/<id>.config.toml   effective configuration of that session
├── sessions/<id>.manifest.toml resolved manifest of that session
├── sessions/<id>.hardware.txt  hardware fingerprint of that session
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
└── run.log
```

In `:elapsed` mode `count_exact + count_gap_crossing = count` at every
support value; in `:exact` mode the distribution holds exact waits only and
`count_gap_crossing` is zero. The censoring histogram counts the
right-censored indices by the lower bound of their waiting time (the elapsed
time to the last observation before the first gap, or to the end of the
record); with the class counts it is what an estimator for censored data
needs. The dense files `waiting_times/delta=<δ>` (`[output].store_waiting_times
= true`) hold one row per index (`tau`, `class`, `lower`, `upper`) and are
needed only for statistics of individual indices. At about 25 bytes per index
and threshold in Arrow and 30 to 40 in CSV, a series of 10⁶ points over a
grid of 1000 thresholds writes some 25 to 40 GB.

Rerunning with a wider threshold grid adds partitions and appends a session;
existing partitions are skipped unless `[output].overwrite = true`, in which
case they are backed up as `<name>#k.<ext>` first. Before it extends a
collection, a session compares the series it prepared with the stored one and
stops if they differ: the identifiers hash the configuration, and a reader
option outside the identity (`format`, `delimiter`, `header`) or another
version of the preprocessing can give another series under the same
identifier.

`index.toml` and `summary.csv` are rewritten at every checkpoint
(`[run].checkpoint_seconds`, 10 s by default), at the end of the session, and
when the session stops on an error or an interrupt, so an interrupted run
resumes from the partitions already written. A threshold enters the index once
all its files are written, and one rewritten under `[output].overwrite` leaves
it before its files are backed up, so a killed process, or an error while the
files of one threshold are written, leaves those files out of the index; the
next run computes that threshold again and backs up the files it finds in their
place. The identity, the stored series and the memory bound are checked before
a session writes anything but its log. `metadata.toml` lists the sessions that
completed; an interrupted one is known by its record under `sessions/`, still
at `status = "running"`, and by the index entries that name it. With reference
checks enabled the kernel is first compared with the reference kernel on the
largest pending threshold whose reference work is within
`[limits].max_reference_work`, before any partition is written, and on further
thresholds after the last one. A disagreement there removes every threshold of
the session from the index before the error is raised, so the next run
computes them again.

## Validate

[`validate`](@ref) compares the configured kernel, or a given list of kernels
(`kernels`), with the reference kernel on chosen
thresholds and reports equality, the number of differing indices and the
reference kernel's cost. It returns a [`ValidationReport`](@ref) with one
[`ComparisonResult`](@ref WaitingTimes.Orchestrator.ComparisonResult) per
kernel and threshold and one
[`KernelSummary`](@ref WaitingTimes.Orchestrator.KernelSummary) per kernel.
`scripts/validate.jl` exits non-zero on any disagreement.

## Scripts

```
julia --threads=auto scripts/run_pipeline.jl --config configs/geisenheim_wind.toml
julia scripts/launch_run.jl --config configs/geisenheim_wind.toml
julia scripts/prepare.jl --config configs/geisenheim_wind.toml
julia --threads=auto scripts/validate.jl --config configs/quickstart.toml --deltas 0.001,0.005
julia --threads=auto scripts/crosscheck.jl --config configs/quickstart.toml
julia scripts/lineage.jl data/<collection id>
```

Every script activates the scripts environment itself
(`scripts/activate.jl`). `launch_run.jl` starts the pipeline as a detached
process with a console log and a job record (`run_<timestamp>.toml`: process
identifier, command, start time) under `data/logs/`. `run_pipeline.jl` loads
KernelAbstractions and the GPU package named by `[algorithm].backend` when
the configuration uses the device kernel and they are installed, which
activates the corresponding extensions. `crosscheck.jl` compares every kernel
with the configured reference kernel index by index on the threshold grid of
a configuration, or on every K-th threshold with `--every K`; `--env` runs it
in another environment, such as `test/device` for a GPU package.
