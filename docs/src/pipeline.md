# Pipeline

A run is driven by one TOML file ([Configuration](@ref)) and proceeds in
three stages.

## Prepare

[`prepare`](@ref) reads the input (CSV, DAT, Arrow or MarketTickStreamer
tick files) with the configured value and time columns, applies the
preprocessing steps in order (range selection, surgical cuts, trailing-mean
fluctuations in percent, log returns, differences, centred moving-average
detrending, quantile clipping, tie collapsing), quantises to the grid, and
attaches detected and declared gaps. Every step is appended to the series'
`PreparationRecord`. `scripts/prepare.jl` prints sampling and value
diagnostics, the gap table longest first, and an in-terminal overview, so
large gaps can be located and cut before a run.

## Generate

[`generate`](@ref) computes every configured threshold not yet present in the
collection, writes one partition per threshold, runs reference checks, and
records the session. The collection directory is

```
data/<collection id>/
├── config.toml            effective configuration of the first session
├── metadata.toml          identity, series and dataset provenance, session list
├── hardware.txt           fingerprint of the latest session
├── sessions/<id>.toml     per-session record: kernel, backend, git, timings, reference checks
├── sessions/<id>.config.toml   effective configuration of that session
├── series.<csv|arrow>     prepared series (values, times), gaps.csv, series.toml
├── distributions/delta=<fixed>.<csv|arrow>
├── waiting_times/         optional dense waiting-time vectors with classes and bounds
├── index.toml             partitions with checksums and per-threshold statistics
├── summary.csv            one row per threshold
├── catalog.csv            every artefact with its descriptor columns
└── run.log
```

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
