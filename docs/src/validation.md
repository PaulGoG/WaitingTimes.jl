# Validation

The naive scan is the definition and the permanent reference kernel. Every other
kernel is validated against it at several levels.

| Tier | Where | What |
|---|---|---|
| Static | `test/runtests.jl` | Aqua, JET with `target_modules`, ExplicitImports (no implicit or stale imports, owner-qualified imports and accesses) |
| Unit | `test/runtests.jl` | hand-computed series including ties, censoring, missing samples and gaps; quantisation and threshold formatting round trips; overflow guard; series validation |
| Equivalence | `test/runtests.jl` | eight synthetic families (random walks with drift, cycles, jumps and heavy tails, independent samples, few distinct values, missing runs, irregular time stamps) at ``10^3``, ``10^4`` and ``10^5`` points; every kernel bit-identical to the reference kernel for seven thresholds from 0 to beyond the range; streaming equality on every prefix |
| Invariants | `test/runtests.jl` | monotonicity in ``\delta``, accounting identities, ``\delta = 0`` monotonic-stack solution, gap invariance |
| Fixtures | `test/fixtures/` | EUR-USD daily rate with four legacy distribution files reproduced exactly by the new formulation, standalone and through the pipeline |
| Pipeline | `test/pipeline_tests.jl` | configuration errors and warnings, provenance hashing and overlays, name grammar, every preprocessing transform, storage round trips, an end-to-end run with resume, extension of the grid, overwrite with backups, validation, and both package extensions |
| Device | `test/device/` | opt-in: the oneAPI kernel on the local Intel GPU against the reference kernel and the segment tree at ``10^5`` and ``10^6`` points |
| Dense | `scripts/crosscheck.jl` | every kernel against the reference kernel on every threshold of the six dataset configurations (7 124 thresholds, EUR-USD to TRUSTEE, up to 10⁶ points): zero differing indices; rerun for any new kernel or dataset |
| Published results | `examples/published_fits.jl` | Table 1 of Gogîță et al. (2026) recomputed from the shipped configurations with the fitting recipe of the 2024 analysis, for the datasets whose inputs they reference (wind speed, daily solar index, ionospheric TEC, Trieste sea level with the published preprocessing, EUR-USD): every entry to the printed precision, α to three decimals and D_KS to three significant digits |
| Production | every run | `[algorithm].reference_checks` thresholds recomputed with the reference kernel and compared exactly, recorded in the session |

Benchmarks in `bench/run_benchmarks.jl` time every kernel on synthetic random
walks up to ``4 \cdot 10^6`` points and abort on any disagreement.
