# References

- P.-A. Gogîță, T.-G. Dumitru, F.-I. Constantin, T.-A. Diac, A.-F. Neagoe,
  M.-C. Raportaru, A. Nicolin-Żaczek, Scale-free to Pareto-Tsallis transitions
  in the distributions of waiting times: weather, sea-level, currency trading
  and automotive datasets, *J. Phys. Complex.* **7**, 035007 (2026),
  [doi:10.1088/2632-072X/ae8aa5](https://doi.org/10.1088/2632-072X/ae8aa5).
- G. T. Pană, P.-A. Gogîță, A. Nicolin-Żaczek, Waiting times for sea level
  variations in the Port of Trieste: a computational data-driven study,
  *Rom. J. Phys.* **69**, 111 (2024),
  [doi:10.59277/RomJPhys.2024.69.111](https://doi.org/10.59277/RomJPhys.2024.69.111).
  Defines the detrending and pruning of the preprocessed series.
- B. N. Vivirschi, P. C. Boboc, V. Băran, A. I. Nicolin, Scale-free
  distributions of waiting times for earthquakes, *Phys. Scr.* **95**, 044011
  (2020), [doi:10.1088/1402-4896/ab623d](https://doi.org/10.1088/1402-4896/ab623d).
  The waiting time with a magnitude threshold, defined after the investment
  horizon.
- I. Simonsen, M. H. Jensen, A. Johansen, Optimal investment horizons, *Eur.
  Phys. J. B* **27**, 583 (2002),
  [doi:10.1140/epjb/e2002-00193-x](https://doi.org/10.1140/epjb/e2002-00193-x).
  The investment horizon: the shortest time in which the return of an asset
  reaches a given level, the first-passage time that the waiting time
  generalises to any series.
- E. Sparre Andersen, On the fluctuations of sums of random variables II,
  *Math. Scand.* **2**, 194 (1954),
  [doi:10.7146/math.scand.a-10407](https://doi.org/10.7146/math.scand.a-10407);
  R. van der Hofstad, M. Keane, An elementary proof of the hitting time
  theorem, *Am. Math. Mon.* **115**, 753 (2008),
  [doi:10.1080/00029890.2008.11920588](https://doi.org/10.1080/00029890.2008.11920588).
  Exact first-passage laws of random walks, the expected values of the
  exact-law tests ([Validation](validation.md)): the survival probability
  ``\binom{2k}{k} 4^{-k}`` at ``\delta = 0`` for continuous symmetric steps,
  and ``P(\tau = k) = (a/k)\, P(S_k = a)`` for the simple walk at level ``a``.
- A. Clauset, C. R. Shalizi, M. E. J. Newman, Power-law distributions in
  empirical data, *SIAM Rev.* **51**, 661 (2009),
  [doi:10.1137/070710111](https://doi.org/10.1137/070710111).
  The maximum-likelihood exponent of a power-law tail above ``x_{\min}`` for
  integer data (their Eq. 3.7), as fitted in the [Downstream example](@ref)
  and, at every point of an ``x_{\min}`` scan, as the starting value of the
  scale-free fit in `examples/legacy_fit.jl`.
- R. Połoczański, A. Wyłomańska, M. Maciejewska, A. Szczurek, J. Gajda,
  Modified cumulative distribution function in application to waiting time
  analysis in the continuous time random walk scenario, *J. Phys. A* **50**,
  034002 (2017),
  [doi:10.1088/1751-8121/50/3/034002](https://doi.org/10.1088/1751-8121/50/3/034002).
  Fitting waiting times recorded on a grid through their cumulative
  distribution, the approach of the 2024 fit recipe.
- J. L. Bentley, Algorithms for Klee's rectangle problems, unpublished notes,
  Carnegie Mellon University (1977); J. L. Bentley, D. Wood, An optimal worst
  case algorithm for reporting intersections of rectangles, *IEEE Trans.
  Comput.* **C-29**, 571 (1980),
  [doi:10.1109/TC.1980.1675628](https://doi.org/10.1109/TC.1980.1675628).
  Origin of the segment tree used by `SegmentTreeSearch`.
- P. M. Fenwick, A new data structure for cumulative frequency tables,
  *Softw. Pract. Exper.* **24**, 327 (1994),
  [doi:10.1002/spe.4380240306](https://doi.org/10.1002/spe.4380240306). The
  binary indexed tree of `FenwickSweep`.
- O. Berkman, B. Schieber, U. Vishkin, Optimal doubly logarithmic parallel
  algorithms based on finding all nearest smaller values, *J. Algorithms*
  **14**, 344 (1993), [doi:10.1006/jagm.1993.1018](https://doi.org/10.1006/jagm.1993.1018).
  The all-nearest-larger-values problem: at ``\delta = 0`` the passage of
  an index is its nearest larger-or-equal value to the right, found with a
  monotone stack; `StreamingSearch` generalises the stack to ``\delta > 0``
  with a priority queue.
- B. Widrow, I. Kollár, M.-C. Liu, Statistical theory of quantization, *IEEE
  Trans. Instrum. Meas.* **45**, 353 (1996),
  [doi:10.1109/19.492748](https://doi.org/10.1109/19.492748); W. F. Sheppard,
  On the calculation of the most probable values of frequency-constants, for
  data arranged according to equidistant division of a scale, *Proc. Lond.
  Math. Soc.* **s1-29**, 353 (1898),
  [doi:10.1112/plms/s1-29.1.353](https://doi.org/10.1112/plms/s1-29.1.353).
  What rounding to the decimal grid does to a distribution.
- D. Cousineau, How many decimals? Rounding descriptive and inferential
  statistics based on measurement precision, *J. Math. Psychol.* **97**,
  102362 (2020),
  [doi:10.1016/j.jmp.2020.102362](https://doi.org/10.1016/j.jmp.2020.102362).
  The grid step against the dispersion of the quantity, the basis of the
  automatic choice of `digits`.
