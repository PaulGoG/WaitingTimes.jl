# Provenance

## Identifiers

Every artefact carries an identifier `<kind>-<slug>-<hash8>` where `hash8`
is the first eight hexadecimal digits of the SHA-256 of the canonical TOML
serialisation of its identity fields (keys sorted, values only).

| Kind | Identity |
|---|---|
| `dataset` | SHA-256 of the raw file, value column, time column, the reader options `format`, `delimiter` and `header`, and the SHA-256 of the source descriptor when one is configured |
| `series` | dataset identifier, time unit and epoch unit, time format, time axis, missing and tie policies, preprocessing steps with the default of every key they omit ([`resolved_step`](@ref WaitingTimes.Config.resolved_step)), digits, gap declaration and detection settings |
| `collection` | series identifier, distribution mode |

The identity covers what determines the series, as the configuration states
it, with the defaults it leaves implicit written out: a step given with or
without its defaults names the same series, and a later change of a default
names another. Kernel, backend, machine and commit are recorded in the session
and not hashed, since every kernel must give the same result; the thresholds
are left out too, so that a collection can be extended later. The version of
the preprocessing code is not hashed: a session that extends a collection
therefore compares the series it prepared with the stored one and stops when
they differ ([Pipeline](pipeline.md)).

## Files

`metadata.toml` (schema `waitingtimes-provenance/4`) holds the schema
version, the `[artefact]` section (identifier, kind, creation time, parents),
the `[identity]`, the `[series]` section, the `[dataset]` section with the
descriptor, the `[source]` section when `[input].source_descriptor` is set,
`[producer]`, `[environment]` and the `[[sessions]]` list of the sessions
that completed.

- `[series]`: the full preparation record (the input file by its path
  relative to `[output].root`, the directory that holds the collection, with
  its size and SHA-256, and every step), digits
  and value type, the time
  axis (`elapsed` or `index`) with the time unit of the series and the time
  unit and epoch of the input's clock (`time_unit_original`,
  `epoch_original`), the number of observations and gaps, the gaps by kind,
  and the record structure: sampling step, record length in sampling steps,
  number of segments.
- `[source]`: the descriptor's table, its file `source.toml` and its
  SHA-256, and the normalised summary of the producer's identity
  ([Source descriptors](@ref)).
- `[producer]`: the code identity of WaitingTimes in the latest session:
  `name`, `version`, `git_tree_sha1`, `git_dirty`, `git_commit`, `repo_url`,
  `repo_rev` and `identity_source` ([Code identity](@ref)).
- `[environment]`: the SHA-256 of the resolved manifest of the latest
  session, the file it is copied to (`manifest_snapshot.toml`) and the Julia
  version.

`index.toml` lists every partition with its file, checksum, session and
per-threshold statistics; `summary.csv` is regenerated from it after every
checkpoint of a session and at its end.

Each session also has its own file under `sessions/`. It records the kernel
and backend, thread count, package version, code identity, git state, Julia
version and configuration hash, the thresholds computed and skipped, the
reference checks and stage timings. It holds the SHA-256 of the session's
manifest, copied to `sessions/<id>.manifest.toml`, and the hardware
fingerprint: host, CPU, cores, memory, BLAS threads and a GPU backend's
device report. Its `status` is `"running"` while the session
computes and `"completed"` once the record is final; a session file still at
`"running"` belongs to an interrupted run, whose partitions `index.toml`
lists up to its last rewrite. `sessions/<id>.hardware.txt`, and `hardware.txt`
for the latest session, carry `versioninfo` and the device report. Arrow partitions also carry the
collection identifier, threshold and session in their schema metadata; CSV
partitions carry none. A collection of schema 2 (WaitingTimes 0.2) is read
with time axis `elapsed`, gaps of kind `unknown`, and without class counts
or censoring histograms. A collection of schema 3 (0.3 and 0.4) reads as
written; schema 4 drops the catalogue and the duplicate observation count
and records kernels as the configuration spells them.

## Code identity

The code that computed a collection is identified by the same fields however
the package was obtained
([`source_identity`](@ref WaitingTimes.Provenance.source_identity)); they are
read:

- from git when the package directory is the top level of a work tree
  (`identity_source = "work_tree"`): `git_commit` is the `HEAD`,
  `git_tree_sha1` its tree, `git_dirty` flags uncommitted changes to tracked
  files;
- from the active manifest's entry for a copy installed by Pkg
  (`"manifest"`): `git_tree_sha1` is the entry's `git-tree-sha1`,
  `git_commit` its `repo-rev` when that is a full commit hash, `git_dirty`
  flags an installed tree that differs from the entry;
- otherwise from the content of the directory (`"directory"`), the tree hash
  computed as git computes it.

`git_tree_sha1` is never empty and, with `git_dirty = false`, fixes the code
exactly; together with the manifest snapshot it makes a collection
attributable to code and environment. Producers of source descriptors are
keyed the same way; DeepSpaceTelemetry.jl records these fields since 2.6.1.

## Lineage

`scripts/lineage.jl <path>` prints the collection, its series with every
preparation step, the dataset with its descriptor, the source descriptor,
the code identity and environment of WaitingTimes in the latest session, the
partitions, and the sessions.
