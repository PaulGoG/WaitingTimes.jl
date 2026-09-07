# Formulation

## Definition

For an observed series ``\{A_n\}_{n=1}^N`` at strictly increasing integer
times ``\{t_n\}`` and a threshold ``\delta \ge 0``,

```math
\tau_n(\delta) = t_m - t_n, \qquad m = \min\{\, m > n : A_m \ge A_n + \delta \,\},
\qquad n = 1, \dots, N-1 .
```

The comparison is ``\ge``: at ``\delta = 0`` a repeated value ends the wait at
the next equal-or-greater sample. Index ``N`` has no successor and is never a
candidate. An index without such an ``m`` is right-censored and contributes no
waiting time; its count is reported with every distribution.

## Decimal integer grid

The precision parameter is `digits`. Values are quantised once,

```math
q_n = \operatorname{round}\!\left(A_n \cdot 10^{\mathrm{digits}}\right),
```

with the same half-to-even rounding as `round(x; digits)`, so grid assignment
equals the rounding of the original analysis. Thresholds are integers
``d = \delta \cdot 10^{\mathrm{digits}}``, validated to be exact. After
quantisation no floating-point arithmetic occurs in any kernel on any backend:
every kernel writes the same result vector and equivalence is tested with
`==`. A threshold is stored as its integer and rendered as a fixed-decimal
string with exactly `digits` decimals (`delta=0.0005`), so matching
thresholds across files is integer matching.

## Time axis, missing samples and gaps

`t_n` is the sample index by default, a regular cadence read from a timestamp
column (`:hour`, `:day`, …), or raw irregular time stamps (`:nanosecond`
since the UNIX epoch for tick data). Irregular spacing is accepted as such.
Equal time stamps are resolved only by an explicit, recorded step
(`tie_policy`).

Semantics follow the original analysis: the search runs over the observed
samples and time passes through missing samples and data gaps, so a waiting
time is the *elapsed* time to the first observed passage. Every observation
is used. Gaps (runs of missing samples, declared intervals from schedules or
quality logs, or intervals detected by a threshold) are stored with the
series and reported; they never alter a waiting time. The classification
[`classify`](@ref) qualifies every index as exact, gap-crossing (a gap lies
between the index and its observed passage, so the true waiting time is only
bracketed) or right-censored, and the distribution records the three counts.
An `:exact` mode that keeps only exact waits exists for comparison studies
and is not a default anywhere.

## Empirical distribution

For each threshold the multiset ``\{\tau_n\}`` over uncensored indices is
summarised by its sorted distinct values, their counts, the probability mass
``p_k``, the cumulative distribution ``P(\tau \le k)`` and the survival
function ``P(\tau > k)``, together with the counts of candidates, exact,
gap-crossing and right-censored indices. Counts are stored so that later
fits can weight and resample.

## Invariants

The test suite enforces: constant series (``\delta = 0`` yields the sample
spacing, ``\delta > 0`` censors everything); strictly increasing series;
pointwise monotonicity ``\tau_n(d) \ge \tau_n(d')`` for ``d \ge d'`` whenever
both exist, with a censored set growing in ``d``; the accounting identities;
equality of ``\delta = 0`` with the monotonic-stack next-greater-or-equal
oracle; rejection of thresholds off the grid; invariance of every waiting
time under declaration or detection of gaps; and equality of the streaming
kernel with the batch oracle on every prefix of a record.
