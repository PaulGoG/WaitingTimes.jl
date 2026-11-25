# Test fixtures

Inputs and reference outputs the test suite compares against. The files are compared byte for
byte and hashed, so `.gitattributes` switches line-ending conversion off for this directory.

| Path | Content |
|---|---|
| `fiatEURUSD.dat` | EUR-USD daily closing rate, 11 572 values; the file described by `configs/datasets/eur_usd-closing_rate.toml` |
| `legacy/` | distributions written by the 2024 generator from `fiatEURUSD.dat`: four decimals, no preprocessing, δ = 0.0005, 0.005, 0.05, 0.5 |
| `sealevelTrieste_1927_1928.csv` | header and first 17 544 rows (the years 1927 and 1928, 189 of them without a value) of the hourly record described by `configs/datasets/trieste-sea_level.toml`, verbatim |
| `legacy_trieste/` | distributions written by the 2024 generator from `sealevelTrieste_1927_1928.csv` under the published treatment: one decimal, percentage fluctuations from the 708-hour rolling average, pruning; δ = 0, 0.5, 5, 20 |
| `schema2/`, `schema3/` | collections of the earlier provenance schemas for the read-side tests; each has its own `README.md` |

The legacy files have the columns `time`, `pdf` and `cdf`, separated by spaces, with CRLF line
ends. Those of `legacy/` are outputs kept with that code, and a rerun of it on 2026-11-17 gave
the same bytes. Those of `legacy_trieste/` were written on 2026-11-25 by the same code,
unchanged apart from its dataset settings, under Julia 1.13.4 with CSV 0.10.17 and DataFrames
1.8.3. The two years were chosen because the pruning rule is decided on them: the 2024 code
removes 70 values, a rule that takes the pruned share of every row instead of the observed
values removes 73. Sources and licences of the two records are in their dataset descriptors.

SHA-256 of the Trieste files:

```
1ded564fcce7796d2b245ea8256fb2f44dcca8a6833195c167ae5520135741e4  sealevelTrieste_1927_1928.csv
f02b4a5efead567fd3677c89e1f2ee17602f08b2dad4d9c12f3feb41611daaac  legacy_trieste/WTS_slvlTrst_slvlhght_pRAF_deltais0.0.dat
e2cd00f7be17673b5ae8ae7e7cfe085747b6c5b7a3295b6986f631deafe098de  legacy_trieste/WTS_slvlTrst_slvlhght_pRAF_deltais0.5.dat
48ea99e4502284aa96108a5f1be524b31860f335555cee4c0f787b383f1f99b2  legacy_trieste/WTS_slvlTrst_slvlhght_pRAF_deltais5.0.dat
736c7ace4d7d14c149c4113324a8f609407d20f2fe638e127b37c8647f874396  legacy_trieste/WTS_slvlTrst_slvlhght_pRAF_deltais20.0.dat
```
