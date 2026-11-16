# References

The waiting time with a threshold is the investment horizon of
[Simonsen2002](@citet), the shortest time in which the return of an asset
reaches a given level, which [Vivirschi2020](@citet) adapted to earthquake
magnitudes. [Pana2024](@citet) applied it to the sea level of Trieste and
defined the detrending and pruning of the preprocessed series;
[Gogita2026](@citet) followed the distributions across thresholds in
weather, sea-level, currency and automotive data.

The exact-law tests ([Validation](validation.md)) take their expected values
from the first-passage theory of random walks: the survival probability
``\binom{2k}{k} 4^{-k}`` at ``\delta = 0`` for continuous symmetric steps
[SparreAndersen1954](@cite) and ``P(\tau = k) = (a/k)\, P(S_k = a)`` for the
simple walk at level ``a`` [vanderHofstad2008](@cite).

`SegmentTreeSearch` uses the segment tree [Bentley1977, BentleyWood1980](@cite)
and `FenwickSweep` the binary indexed tree [Fenwick1994](@cite). At
``\delta = 0`` the passage of an index is its nearest larger-or-equal value to
the right, the all-nearest-larger-values problem [Berkman1993](@cite), found
with a monotone stack; `StreamingSearch` generalises the stack to
``\delta > 0`` with a priority queue.

The automatic choice of `digits` rests on what rounding to a grid does to a
distribution [Widrow1996, Sheppard1897](@cite) and on the grid step measured
against the dispersion of the quantity [Cousineau2020](@cite).

```@bibliography
```
