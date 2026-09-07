# Provenance

## Identifiers

Every artefact carries an identifier `<kind>-<slug>-<hash8>` where `hash8`
is the first eight hexadecimal digits of the SHA-256 of the canonical TOML
serialisation of its identity fields (keys sorted, values only).

| Kind | Identity |
|---|---|
| `dataset` | SHA-256 of the raw file, value column, time column |
| `series` | dataset identifier, time unit and epoch unit, missing and tie policies, preprocessing steps, digits, gap declaration and detection settings |
| `collection` | series identifier, distribution mode |

Identity is mathematical: which kernel, backend, machine or commit produced
the numbers is recorded in the session, never hashed, because every kernel
must produce the same result. Thresholds are not part of a collection's
identity, so a collection can be extended with more thresholds later.

## Files

`metadata.toml` holds the schema version, the `[artefact]` section
(identifier, kind, creation time, parents), the `[identity]`, the `[series]`
section with the full preparation record, the `[dataset]` section with the
descriptor, and the `[[sessions]]` list. Each session also has its own file
under `sessions/` with the kernel and backend, thread count, package version,
git state (commit, tags, dirty flag), Julia version, hardware fingerprint
(host, CPU, cores, memory, BLAS threads, and the device report of a GPU
backend), configuration hash, thresholds computed and skipped, oracle checks
and stage timings. `hardware.txt` carries `versioninfo` and the device
report. Arrow partitions also carry the collection identifier, threshold and
session in their schema metadata; CSV partitions stay clean.

`index.toml` lists every partition with its file, checksum, session and
per-threshold statistics; `summary.csv` and `catalog.csv` are regenerated
from it after every session.

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
preparation step, the dataset with its descriptor, and the sessions.
