# Validation

The naive scan is the definition and the permanent reference kernel. Every other
kernel is validated against it at several levels.

| Tier | Where | What |
|---|---|---|
| Static | `test/runtests.jl` | Aqua, JET with `target_modules`, ExplicitImports (no implicit or stale imports, owner-qualified imports and accesses) |
| Unit | `test/runtests.jl` | hand-computed series including ties, censoring, missing samples and gaps; quantisation and threshold formatting round trips; overflow guard; series validation |
| Equivalence | `test/runtests.jl` | eight synthetic families (random walks with drift, cycles, jumps and heavy tails, independent samples, few distinct values, missing runs, irregular time stamps) at ``10^3`` and ``10^4`` points, the first two also at ``10^5``; every kernel bit-identical to the reference kernel for seven thresholds from 0 to beyond the range (at ``10^5`` without the fully censored one); the streaming state and the online estimator equal to the reference kernel on every prefix of a 300-sample record |
| Invariants | `test/runtests.jl` | monotonicity in ``\delta``, accounting identities, ``\delta = 0`` monotonic-stack solution, gap invariance |
| Exact laws | `test/runtests.jl` | closed-form first-passage counts over complete ensembles: independent values on a finite grid for every threshold, and all ``2^{12}`` simple random walks by the hitting-time theorem; the Sparre Andersen survival probability ``\binom{2k}{k} 4^{-k}`` of walks with continuous symmetric steps at ``\delta = 0``, within five standard errors [SparreAndersen1954, vanderHofstad2008](@cite) |
| Fixtures | `test/fixtures/` | EUR-USD daily rate with four legacy distribution files reproduced exactly, standalone and through the pipeline; the first two years of the Trieste record under the published treatment (fluctuations from the trailing mean, pruning) with four distribution files of the 2024 code reproduced exactly |
| Pipeline | `test/pipeline_tests.jl` | configuration errors and warnings, provenance hashing and overlays, every preprocessing transform, storage round trips, an end-to-end run with resume, extension of the grid, overwrite with backups, validation, and the Distributions and CairoMakie extensions |
| Device | `test/device/` | opt-in: the oneAPI kernel on an Intel GPU against the reference kernel and the segment tree at ``10^5`` and ``10^6`` points |
| Dense | `scripts/crosscheck.jl` | every kernel against the reference kernel on every threshold of the six dataset configurations (7 124 thresholds, EUR-USD to TRUSTEE, up to 10⁶ points): zero differing indices in the runs of 2026-09-26 (version 0.1.0) and 2026-11-25 (commit `8b506cb`), the device kernel on the CPU backend included |
| Production | every run | `[algorithm].reference_checks` thresholds recomputed with the reference kernel and compared exactly, recorded in the session |

Benchmarks in `bench/run_benchmarks.jl` time every kernel on synthetic random
walks up to ``4 \cdot 10^6`` points and abort on any disagreement.
