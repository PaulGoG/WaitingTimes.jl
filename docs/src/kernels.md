# Kernels

Every kernel writes ``\tau_n`` into its own slot of a dense result vector
(sentinel `0` for no observed passage), so results are deterministic and
comparable with `==` across kernels and backends.

| Kernel | Cost per threshold | Parallelism | Role |
|---|---|---|---|
| [`NaiveSearch`](@ref) | ``O(\sum_n \tau_n)``, worst ``O(N^2)`` | over indices, chunked dynamic scheduling | the definition; permanent oracle |
| [`GuardedSearch`](@ref) | same, censored indices skipped in ``O(1)`` | over indices | oracle with the suffix-maximum censoring proof |
| [`SegmentTreeSearch`](@ref) | ``O(N \log N)``, insensitive to ``\delta`` | over indices | production kernel |
| [`FenwickSweep`](@ref) | ``O(N \log V)``; any number of thresholds per sweep | over thresholds | dense grids, few cores, small memory |
| [`StreamingSearch`](@ref) | ``O(N \log N)``, one pass, no lookahead | none | live pipelines; equals the oracle on every prefix |
| [`DeviceSearch`](@ref) | ``O(\sum_n \tau_n)`` | one work-item per index on a KernelAbstractions backend | oracle on GPUs |

## Segment tree

A maximum segment tree over the positions answers, for each index, the
leftmost later position whose value reaches the target: climb to the first
right sibling whose maximum qualifies, then descend to its leftmost
qualifying leaf, ``O(\log N)``. The tree is built once per series and is
read-only during queries. Benchmarks on synthetic random walks with 22
threads: ``4 \cdot 10^6`` points at large ``\delta`` in 33 ms per threshold,
while the naive scan needs about 7 s at ``10^6`` points.

## Fenwick sweep

Sweeping the series from the end, a Fenwick tree over the ranks of the
distinct values holds the smallest index seen for each value; the passage of
an index is the minimum index among values at least its target, a
prefix-minimum query. Several thresholds share one sweep.

## Streaming

Pending indices wait in a min-heap keyed by their target ``q_n + d``. Each
arriving sample resolves every pending index whose target it reaches and then
joins the heap; the heap contents are the right-censored set so far. A
[`StreamingState`](@ref) is fed with [`update!`](@ref) and a
[`DistributionAccumulator`](@ref) turns resolved waits into a distribution
incrementally, for embedding in real-time detection pipelines.

## Device kernel

The naive scan as a KernelAbstractions kernel with one work-item per index
and the host-computed suffix maxima for the censoring test. The CPU backend is
always available and runs in the default test suite; loading CUDA, oneAPI,
AMDGPU or Metal registers a GPU backend probe through a package extension,
and [`device_search`](@ref) selects it. Device access is serialised and the
series arrays are uploaded once per series. Opt-in device tests live in
`test/device/`.

## Choosing a kernel

`SegmentTreeSearch` is the default of [`waiting_times`](@ref) and of the
pipeline. Production runs recompute a configurable number of thresholds with
the oracle and compare exactly (`[algorithm].oracle_checks`); the work of an
oracle check, ``\sum_n \tau_n``, is known from the fast result before the
oracle is launched and is bounded by `[limits].max_naive_work`.
