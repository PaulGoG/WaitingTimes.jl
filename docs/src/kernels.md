# Kernels

Every kernel writes ``\tau_n`` into its own slot of a dense result vector
(sentinel `0` for no observed passage), so results are deterministic and
comparable with `==` across kernels and backends.

| Kernel | Cost per threshold | Parallelism | Role |
|---|---|---|---|
| [`NaiveSearch`](@ref) | ``O(\sum_n \tau_n)``, worst ``O(N^2)`` | over indices, chunked dynamic scheduling | the definition; permanent reference kernel |
| [`GuardedSearch`](@ref) | same, censored indices skipped in ``O(1)`` | over indices | the naive scan under a suffix-maximum guard; admitted as `reference_kernel` where the naive scan is too slow |
| [`SegmentTreeSearch`](@ref) | ``O(N \log N)``, insensitive to ``\delta`` | over indices | production kernel |
| [`FenwickSweep`](@ref) | ``O(N \log V)``; any number of thresholds per sweep | none (sequential in ``n``) | dense grids, few cores, small memory |
| [`StreamingSearch`](@ref) | ``O(N \log N)``, one pass, no lookahead | none | live pipelines; equals the reference kernel on every prefix |
| [`DeviceSearch`](@ref) | ``O(\sum_n \tau_n)`` | one work-item per index on a KernelAbstractions backend | the guarded scan on GPUs |

## Segment tree

A maximum segment tree over the positions answers, for each index, the
leftmost later position whose value reaches the target: climb to the first
right sibling whose maximum qualifies, then descend to its leftmost
qualifying leaf, ``O(\log N)``. The tree is built once per series and is
read-only during queries. On synthetic random walks with 22 threads it
answers ``4 \cdot 10^6`` points at large ``\delta`` in 33 ms per threshold;
the naive scan needs about 7 s at ``10^6`` points.

## Fenwick sweep

Sweeping the series from the end, a Fenwick tree over the ranks of the
distinct values holds the smallest index seen for each value; the passage of
an index is the minimum index among values at least its target, a
prefix-minimum query. Several thresholds share one sweep through
`waiting_times(s, deltas, FenwickSweep())`, which saves the tree updates but
not the per-threshold queries, so it is at most 1.5 times faster than
separate sweeps.
[`run_pipeline`](@ref) serves the thresholds of a session in batches with the
Fenwick sweep, bounded by `[limits].max_ram_gb`, and one at a time with the
other kernels.

## Streaming

Pending indices wait in a min-heap keyed by their target ``q_n + d``. Each
arriving sample resolves every pending index whose target it reaches and then
joins the heap; the heap contents are the right-censored set so far. A
[`StreamingState`](@ref) is fed with [`update!`](@ref WaitingTimes.update!) and a
[`DistributionAccumulator`](@ref) turns resolved waits into a distribution
incrementally, for embedding in real-time detection pipelines.

After ``t`` samples the heap holds ``E[\min(\tau, t)]`` entries on average:
``O(\log t)`` for independent values, ``O(\sqrt{t})`` for a random walk,
``O(t)`` when a fraction ``p_\infty`` of the indices never resolves (downward
drift, bounded values at thresholds near their range). A declared
`upper_bound` removes the provably unreachable entries without changing any
result; a `horizon` ``H`` evicts entries older than ``H`` as censored and
bounds the heap by twice the samples within one horizon, at a cost within
25 % of the unbounded state (random walk, ``10^6`` points).

## Device kernel

`DeviceSearch` is the guarded scan as a KernelAbstractions kernel, with one
work-item per index and the host-computed suffix maxima for the censoring
test. A package extension provides it: `using KernelAbstractions` enables it on
the CPU backend, and loading CUDA, oneAPI, AMDGPU or Metal registers that GPU
backend, which [`device_search`](@ref) selects. Device access is serialised
and the series arrays are uploaded once per series. The CPU backend runs in
the default test suite; opt-in device tests live in `test/device/`.

## Default kernel and reference checks

`SegmentTreeSearch` is the default of [`waiting_times`](@ref) and of the
pipeline. Production runs recompute a configurable number of thresholds with
the reference kernel and compare exactly (`[algorithm].reference_checks`).
The cost of a reference check is known before it is launched:
[`WaitingTimes.scan_work`](@ref) counts, from the fast result, the element
comparisons the scan will perform (``m - n`` for an index resolved at
position ``m``, ``N - n`` for a right-censored index under `NaiveSearch`), in
index units whatever the time unit; `[limits].max_reference_work` bounds it.
