"""
Exact waiting-time distributions of scalar time series for threshold grids.

Given a series ``\\{A_n\\}`` observed at strictly increasing integer times
``\\{t_n\\}`` and a threshold ``\\delta \\ge 0``, the waiting time of index ``n`` is
``\\tau_n = t_m - t_n`` with ``m = \\min\\{m > n : A_m \\ge A_n + \\delta\\}``, the
elapsed time to the first observed value at least ``\\delta`` above ``A_n``.
Values and thresholds live on a decimal integer grid (`digits`), so the search
kernels compute bit-identical results; each is checked against the naive
scan, the permanent reference kernel.
"""
module WaitingTimes

using DataStructures: BinaryMinHeap, extract_all!
using Dates: DateTime
using DocStringExtensions: TYPEDFIELDS, TYPEDSIGNATURES
using OhMyThreads: tforeach
using Statistics: Statistics

"""
Package directory at precompilation, the parent of `src/`. A depot moved after
precompilation keeps the compiled code and leaves this constant at the old
location; `pkgdir(WaitingTimes)` is the directory of the loaded code, which the
code identity hashes.
"""
const PACKAGE_ROOT = normpath(joinpath(@__DIR__, ".."))

# the directory of the loaded code, also after the depot has been moved
package_root() = something(pkgdir(@__MODULE__), PACKAGE_ROOT)

include("Quantization.jl")
include("Series.jl")
include("Gaps.jl")
include("Describe.jl")
include("Kernels.jl")
include("SegmentTree.jl")
include("FenwickSweep.jl")
include("Distribution.jl")
include("Streaming.jl")
include("Online.jl")
include("Synthetic.jl")
include("Backends.jl")
include("DeviceKernels.jl")

"""
    discrete_distribution(d::WaitingTimeDistribution)

`Distributions.DiscreteNonParametric` over the support of `d` with its
probability masses, so that the standard `cdf`, `ccdf`, `quantile`, `mean` and
`rand` methods apply; `DiscreteNonParametric(d)` is the same. An empty
distribution raises an `ArgumentError`. Provided by the Distributions
extension (`using Distributions`).
"""
function discrete_distribution end

"""
    plot_series(s::QuantizedSeries; quantity_label = "", unit_label = "",
                max_points = 5_000, size = (900, 600))

Figure of the series against time, in data units, with its gaps shaded. The
series is decimated with the stride `max(1, N ÷ max_points)`, so fewer than
`2 max_points` samples are drawn. When there are gaps, a legend on top names
the series and states their number and their share of the record. Provided by
the CairoMakie extension (`using CairoMakie`).
"""
function plot_series end

"""
    plot_distribution(d::WaitingTimeDistribution; size = (1200, 600))

Figure of a distribution: the probability mass (left, markers) and the
survival function (right, staircase) on logarithmic axes that share the
waiting-time axis, with the threshold, the number of waiting times and the
right-censored count annotated. An empty distribution raises an
`ArgumentError`. Provided by the CairoMakie extension.
"""
function plot_distribution end

"""
    plot_values(s::QuantizedSeries; quantity_label = "", unit_label = "",
                bins = :auto, size = (900, 600))

Histogram of the values of `s` in data units. With `bins = :auto` the bin
width is the Freedman–Diaconis width rounded up to a whole number of grid
steps ``10^{-\\mathrm{digits}}``, so that every grid value falls inside one
bin, with at most 200 bins; an integer gives that many bins. The number of
observations and the median are stated in the axis. Provided by the CairoMakie
extension.
"""
function plot_values end

"""
    save_figure(path, fig; sidecar, px_per_unit = 4) -> path

Save `fig` to `path` and write the `sidecar` dictionary, the provenance of the
figure, to `path * ".toml"`. Provided by the CairoMakie extension.
"""
function save_figure end

"""
    figure_theme()

Publication theme of the figures of the package, for `with_theme` or
`set_theme!`: Computer Modern fonts, base font size 26, boxed axes with inward
ticks, no minor ticks, a faint dashed grid, data lines of width 3, markers of
size 14, frameless horizontal legends. Marker outlines have width 1.5 and no
colour of their own (`markerstrokewidth`, `markerstrokecolor`), for `scatter`
and for the recipes that draw markers, such as `scatterlines`: a marker is
outlined when `strokecolor` is given, for instance
[`stroke_color`](@ref)`(color)`, and the markers that recipes draw without a
stroke colour, such as the caps of `errorbars` and `rangebars`, keep the colour
of their series. Provided by the CairoMakie extension.
"""
function figure_theme end

"""
    stroke_color(color; factor = 0.6)

Outline colour for a marker drawn in `color`: the same hue, darker, with the
red, green and blue components scaled by `factor` in (0, 1] and the opacity
kept; a vector of colours gives a vector. Pass it as `strokecolor`; under
[`figure_theme`](@ref) a marker is outlined only when a stroke colour is
given. Provided by the CairoMakie extension.
"""
function stroke_color end

"""
    decade_ticks(lo::Integer, hi::Integer)

Tick positions `10^lo, …, 10^hi` with the labels `1`, `10`, `10²`, … for a
logarithmic axis (`10^0` as `1`, `10^1` as `10`); pass the result as `xticks`
or `yticks`. Provided by the CairoMakie extension.
"""
function decade_ticks end

include("Provenance.jl")
include("Config.jl")
include("Preprocessing.jl")
include("Monitoring.jl")
include("Storage.jl")
include("Orchestrator.jl")

using .Config: Settings, load_settings, threshold_list
using .Orchestrator: CollectionHandle, PreparedSeries, ValidationReport, generate, prepare,
                     run_pipeline, validate
using .Storage: Collection, load_collection, list_collections, distribution, thresholds,
                summary_table, load_series, export_legacy, source_descriptor,
                censoring_histogram
using .Provenance: effective_config, source_summary

export Threshold, threshold, quantize, format_threshold, parse_threshold
export PreparationStep, PreparationRecord, QuantizedSeries
export detect_gaps, declare_gaps, gap_table, classify, class_counts, class_totals
export AbstractSearch, NaiveSearch, GuardedSearch, SegmentTreeSearch, FenwickSweep,
       StreamingSearch, DeviceSearch, device_search, waiting_times, waiting_times!
export StreamingState, DistributionAccumulator, pending
export OnlineWaitingTimes, snapshot, status
export WaitingTimeDistribution, empirical_distribution
export Settings, load_settings, threshold_list, effective_config
export CollectionHandle, PreparedSeries, ValidationReport, generate, prepare, run_pipeline,
       validate
export Collection, load_collection, list_collections, distribution, thresholds,
       summary_table, load_series, export_legacy, source_descriptor

public CLASS_EXACT, CLASS_GAP_CROSSING, CLASS_RIGHT_CENSORED, TIME_UNITS, update!
public narrow_integer, GRID_TOLERANCE, on_grid, suffix_maximum, SearchWorkspace, workspace,
       workspace_bytes, scan_work, check_threshold, duration
public support, counts, probabilities, cumulative, survival, nsamples, mean_waiting_time,
       ks_distance
public GAP_KINDS, with_step, sampling_step, record_length, observed_mask, segment_lengths,
       segment_table, describe, SeriesDescription, censoring_histogram, source_summary
public discrete_distribution, plot_series, plot_distribution, plot_values, save_figure,
       figure_theme, stroke_color, decade_ticks, PACKAGE_ROOT
public Synthetic, Backends, Provenance, Config, Preprocessing, Storage, Orchestrator

include("precompile.jl")

end # module
