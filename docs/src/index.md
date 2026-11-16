# WaitingTimes.jl

Exact waiting-time distributions of scalar time series for threshold grids.

Given a series ``A_1, \dots, A_N`` observed at strictly increasing integer
times ``t_1, \dots, t_N`` and a threshold ``\delta \ge 0``, the waiting time of
index ``n`` is

```math
\tau_n = t_m - t_n, \qquad m = \min\{\, m > n : A_m \ge A_n + \delta \,\},
```

the elapsed time to the first observed value at least ``\delta`` above
``A_n``. The distribution of ``\{\tau_n\}`` over a grid of thresholds is the
dynamical fingerprint studied by [Gogita2026](@citet), where it shows a
scale-free regime at small ``\delta`` and a Pareto-Tsallis regime at large
``\delta`` across weather, sea-level, currency and automotive data. The
package ends at the distributions: fitting models to them is left to the
downstream tools, which read the collections it writes
([Interfacing](interfacing.md)).

The package computes these distributions exactly and reproducibly. Values
and thresholds are integers on a decimal grid, so every kernel produces
bit-identical results; the naive scan is the reference implementation the
others are checked against ([Formulation](formulation.md)). Production runs
use a segment-tree kernel at milliseconds per threshold; a Fenwick sweep
suits dense grids, a streaming kernel live pipelines, and a
KernelAbstractions kernel runs the guarded scan on GPUs
([Kernels](kernels.md)). A validated TOML configuration
drives a run from ingestion to the written collection, which records its own
provenance; an interrupted run resumes, and reference checks recompute part
of the grid with the reference kernel ([Pipeline](pipeline.md),
[Configuration](configuration.md), [Provenance](provenance.md)).

## Contents

```@contents
Pages = ["formulation.md", "kernels.md", "pipeline.md", "configuration.md",
    "provenance.md", "validation.md", "interfacing.md", "producers.md",
    "generated/downstream.md", "api.md", "internals.md", "references.md"]
Depth = 1
```
