# Producers

Series reach WaitingTimes through files, sampled or event-driven, and
through two producers whose output the package reads directly:
DeepSpaceTelemetry.jl, which simulates the telemetry chain of a deep-space
mission and writes run directories, and MarketTickStreamer.jl, which
captures, replays and compacts trade ticks. A consumer of a collection sees
only the collection; what follows states how each input becomes one, so that
the collection carries the same fields whatever the input. The two worked
examples, `examples/telemetry_run.jl` and `examples/tick_stream.jl`, run in
the continuous integration against the producer versions pinned in
`examples/Project.toml` and assert the contract below, so that a change of a
producer that breaks it fails there.

## The collection contract

Whatever the input, a collection of provenance schema
`waitingtimes-provenance/3` holds

- the source descriptor of the input verbatim (`source.toml`) and its
  normalised summary (`[source]` of `metadata.toml`: producer, version, code
  identity, version check), when the input names one;
- the code identity of WaitingTimes and the resolved manifest of every
  session (`[producer]`, `[environment]`, `manifest_snapshot.toml`);
- the gaps with their kinds and sources (`gaps.csv`), the segments between
  them (`segments.csv`) and the record structure in `[series]`;
- the time axis and the clock of the input (`[series]`, `series.<ext>`, and
  `gaps_original.csv` on the index axis);
- per threshold the distribution with its counts split by class and the
  histogram of the censoring bounds.

## DeepSpaceTelemetry.jl

A finished run directory (`RUN_COMPLETE`) of DeepSpaceTelemetry 2.5 or later
provides everything a collection needs. The delivered batches under
`ground/<BATCH>/` hold `metadata.json` (`content_epoch`, `payload_row`) and
`seg_<id>.csv` (one column per payload column); sample `k` of a batch lies
at `content_epoch + (k - 1) / sample_rate`, with the sample rate and the
payload origin from `config_snapshot.toml`. `masks/gaps.csv` declares every
hole of the delivered record with its cause, in payload rows (`RowFirst`,
`RowLast`, inclusive) and in mission time (`ContentStart`, `ContentEnd`,
half-open); `holes.csv` is the same table as a feed, each hole with the
instant it was declared. `descriptor.toml` is the run's identity.

| Collection | From the run |
|---|---|
| series | the delivered samples, time in milliseconds from the payload origin; the rows of the holes inside the delivered span as missing values |
| gaps | the holes of `masks/gaps.csv` inside the delivered span, kind `gap` (or of `holes.csv`, kind `hole`), source the file; the spacing of the samples finds the same holes, adjacent ones merged |
| `time_axis = "elapsed"` | mission time on the payload grid |
| `time_axis = "index"` | the payload row, counted from the first delivered row |
| source | `descriptor.toml`; the producer's code is `git_tree_sha1` with `git_dirty`, and `git_commit` when the run was made from a copy pinned by a full commit hash (2.6.1 and later) |

Holes before the first and after the last delivered sample lie outside the
record of the series and are reported, not declared. The tick clock of the
producer (`simulation.mode = "tick"`) runs a scenario deterministically: two
runs of one configuration agree on every product but the wall-clock column of
`mission_profile.csv`.

A Julia consumer reads the run through the producer's adapter
(`DeepSpaceTelemetry.RunAdapter`, public since 2.6.2): `open_run` checks the
producer's version and the lifecycle sentinel, `run_geometry` gives the
sample rate, the payload origin and the clock mode, `list_batches` and
`read_batch` the delivered payload with its payload rows (`row_time` the
instant of a row), and `declared_holes` the feed; the tables of the run are
read with `TelemetryCore.read_table`, which states their column types. This
is what `examples/telemetry_run.jl` does; the file contract serves a
consumer in any other language.

## MarketTickStreamer.jl

A consumer meets a capture in three ways, all through one `Channel{Trade}`:
the wire (`live_source`), a recording (`replay_source`: a session from its
raw files, or a corpus from the processed tree one trading day at a time)
and the raw files of a session another process is writing
(`follow_source`, which ends when the session's sidecar leaves `running`; a
finished session is read whole). `OnlineWaitingTimes` consumes the channel
under the producer's snapshot convention (`snapshots`: the state at every
multiple of a period on the exchange clock and once at close, a function of
the sequence alone, so a replay reproduces the snapshots of the live
session). The file contract, fixed by MarketTickStreamer 1.0.0, serves the
batch pipeline: the processed day files
`processed/<SYMBOL>/<YYYY-MM-DD>.csv|.arrow` (`time_ns`, `price` and the
other trade columns, rows sorted by `time_ns`, exact duplicates removed) are
read with `format = "tick"`, every print a row, equal time stamps resolved by
`tie_policy`; a series over several days is the corpus read
(`read_processed(cfg, symbol; from, to)`) written as one file in the same
schema (`trades_table`). A capture, backfill or import session writes its
sidecar `<session>.meta.toml` with the session, the producer's version,
commit and dirty flag, the venue's timestamp unit, the hardware and the
configuration snapshot (the seed of the backoff jitter included); it records
no tree hash, so a collection from it has no code identity of the producer
beside the version.

| Collection | From the session |
|---|---|
| series | the price-forming prints, time in nanoseconds since the UNIX epoch, at the venue's resolution (`timestamp_unit` of the sidecar: nanoseconds on the SIP, microseconds on Binance) |
| gaps | the exchange closures between regular sessions, kind `session`, from the venue's calendar (`provider_spec`: time zone, regular session; `session_days`); a threshold on the spacing finds the same closures |
| `time_axis = "elapsed"` | exchange time at the stream's resolution |
| `time_axis = "index"` | the trade count; closures close |
| source | the session sidecar |

The prints of one matching event share the exchange timestamp (on a liquid
crypto pair most consecutive prints), so on the elapsed axis `tie_policy`
decides which print of an instant the series keeps; the producer's
`event_bars` collapses them into one bar per instant upstream.

## Sampled files

A CSV, DAT or Arrow file with a value column and an optional time column is
read as it is: the time axis is the time column (or the row), missing values
keep their row, and gaps are detected from the cadence or declared in a
gap file with their kinds ([Gap kinds](@ref)). On the index axis the row of
the file is the time.
