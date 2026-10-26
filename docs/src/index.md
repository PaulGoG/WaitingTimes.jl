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
dynamical fingerprint studied in Gogîță et al., *J. Phys. Complex.* 7 (2026)
035007 ([doi:10.1088/2632-072X/ae8aa5](https://doi.org/10.1088/2632-072X/ae8aa5)),
where it shows a scale-free regime at small ``\delta`` and a
Pareto-Tsallis regime at large ``\delta`` across weather, sea-level,
currency and automotive data.

The package computes these distributions exactly and reproducibly. Values
and thresholds live on a decimal integer grid, so every kernel produces
bit-identical results and the naive scan is the permanent reference
implementation ([Formulation](formulation.md)). A segment-tree kernel serves
production runs in milliseconds per threshold, a Fenwick sweep serves dense
grids and a streaming kernel live pipelines, and a KernelAbstractions kernel
runs the guarded reference scan on GPUs ([Kernels](kernels.md)). A validated
TOML configuration drives ingestion, preprocessing, generation with resume
and reference checks, and provenance ([Pipeline](pipeline.md),
[Configuration](configuration.md), [Provenance](provenance.md)).

## Contents

```@contents
Pages = ["formulation.md", "kernels.md", "pipeline.md", "configuration.md",
    "provenance.md", "validation.md", "interfacing.md", "producers.md",
    "generated/downstream_fit.md", "api.md", "internals.md", "references.md"]
Depth = 1
```
