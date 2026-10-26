# Provenance

## Identifiers

Every artefact carries an identifier `<kind>-<slug>-<hash8>` where `hash8`
is the first eight hexadecimal digits of the SHA-256 of the canonical TOML
serialisation of its identity fields (keys sorted, values only).

| Kind | Identity |
|---|---|
| `dataset` | SHA-256 of the raw file, value column, time column, and the SHA-256 of the source descriptor when one is configured |
| `series` | dataset identifier, time unit and epoch unit, missing and tie policies, preprocessing steps, digits, gap declaration and detection settings, and the time axis when it is `index` |
| `collection` | series identifier, distribution mode |

Identity is mathematical: which kernel, backend, machine or commit produced
the numbers is recorded in the session, never hashed, because every kernel
must produce the same result. Thresholds are not part of a collection's
identity, so a collection can be extended with more thresholds later.

## Files

`metadata.toml` (schema `waitingtimes-provenance/3`) holds the schema
version, the `[artefact]` section (identifier, kind, creation time, parents),
the `[identity]`, the `[series]` section, the `[dataset]` section with the
descriptor, the `[source]` section when `[input].source_descriptor` is set,
`[producer]`, `[environment]` and the `[[sessions]]` list.

- `[series]`: the full preparation record, digits and value type, the time
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

Each session also has its own file under `sessions/` with the kernel and
backend, thread count, package version, code identity, the SHA-256 of its
manifest (copied to `sessions/<id>.manifest.toml`), git state, Julia
version, hardware fingerprint (host, CPU, cores, memory, BLAS threads, and
the device report of a GPU backend), configuration hash, thresholds computed
and skipped, reference checks and stage timings. `status` is `"running"`
while the session computes and `"completed"` once its record is final; a
session file still at `"running"` belongs to an interrupted run, whose
partitions `index.toml` already lists. `hardware.txt` carries
`versioninfo` and the device report. Arrow partitions also carry the
collection identifier, threshold and session in their schema metadata; CSV
partitions carry none. A collection of schema 2 (WaitingTimes 0.2) is read
with time axis `elapsed`, gaps of kind `unknown`, and without class counts
or censoring histograms.

## Code identity

The identity of the code that computed a collection is determined the same
way however the package was obtained
([`source_identity`](@ref WaitingTimes.Provenance.source_identity)): from git
when the package directory is the top level of a work tree (`identity_source
= "work_tree"`, `git_commit` the `HEAD`, `git_tree_sha1` its tree, `git_dirty`
for uncommitted changes to tracked files); from the active manifest's entry
for a copy installed by Pkg (`"manifest"`, `git_tree_sha1` the entry's
`git-tree-sha1`, `git_commit` its `repo-rev` when that is a full commit hash,
`git_dirty` when the installed tree differs from the entry); otherwise from
the content of the directory (`"directory"`, the tree hash computed as git
computes it). `git_tree_sha1` is never empty and, with `git_dirty = false`,
fixes the code exactly; together with the manifest snapshot it makes a
collection attributable to code and environment. Producers of source
descriptors are keyed the same way: DeepSpaceTelemetry.jl records these
fields since 2.6.1.

`index.toml` lists every partition with its file, checksum, session and
per-threshold statistics; `summary.csv` and `catalog.csv` are regenerated
from it after every checkpoint of a session and at its end.

## File names

[`WaitingTimes.Naming.artefact_name`](@ref) builds names of the form

```
<series>__<model>__<representation>__<binning>__delta=<fixed>[__<key>=<value>...]__<id>.<ext>
```

for figures and result tables of later stages, and
[`WaitingTimes.Naming.parse_artefact_name`](@ref) parses them back, so a
batch of files can be inspected and selected from names alone.

## Lineage

`scripts/lineage.jl <path>` prints the collection, its series with every
preparation step, the dataset with its descriptor, the source descriptor,
and the sessions.
