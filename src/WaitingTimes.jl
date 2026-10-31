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

"package directory, the parent of `src/`; the root hashed for the code identity"
const PACKAGE_ROOT = normpath(joinpath(@__DIR__, ".."))

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

`Distributions.DiscreteNonParametric` view of a distribution; provided by the
Distributions extension (`using Distributions`).
"""
function discrete_distribution end

"""
    plot_series(s::QuantizedSeries; quantity_label = "", unit_label = "",
                max_points = 5_000, size = (900, 600))

Figure of a series against time with gaps shaded; provided by the CairoMakie
extension (`using CairoMakie`).
"""
function plot_series end

"""
    plot_distribution(d::WaitingTimeDistribution; size = (1200, 600))

Figure of a distribution (probability mass and survival function on
logarithmic axes); provided by the CairoMakie extension.
"""
function plot_distribution end

"""
    plot_values(s::QuantizedSeries; quantity_label = "", unit_label = "",
                bins = :auto, size = (900, 600))

Histogram of the values of a series, in data units; provided by the
CairoMakie extension.
"""
function plot_values end

"""
    save_figure(path, fig; sidecar, px_per_unit = 4) -> path

Save a figure with a TOML sidecar of descriptor metadata; provided by the
CairoMakie extension.
"""
function save_figure end

"""
    figure_theme()

Publication theme shared by every figure of the package (Computer Modern
fonts, boxed axes, no minor ticks, faint dashed grid); provided by the
CairoMakie extension for use with `with_theme` or `set_theme!`.
"""
function figure_theme end

"""
    decade_ticks(lo::Integer, hi::Integer)

Tick positions and labels at the decades `10^lo` to `10^hi` for logarithmic
axes, rendering `10^0` as `1` and `10^1` as `10`; provided by the CairoMakie
extension.
"""
function decade_ticks end

include("Provenance.jl")
include("Config.jl")
include("Naming.jl")
include("Preprocessing.jl")
include("Monitoring.jl")
include("Storage.jl")
include("Orchestrator.jl")

using .Config: Settings, load_settings, threshold_list
using .Orchestrator: CollectionHandle, generate, prepare, run_pipeline, validate
using .Storage: Collection, load_collection, list_collections, distribution, thresholds,
                summary_table, load_series, export_legacy, source_descriptor,
                censoring_histogram
using .Provenance: effective_config, source_summary

export Threshold, threshold, quantize, format_threshold, parse_threshold
export PreparationStep, PreparationRecord, QuantizedSeries
export detect_gaps, declare_gaps, gap_table, classify, class_counts
export AbstractSearch, NaiveSearch, GuardedSearch, SegmentTreeSearch, FenwickSweep,
       StreamingSearch, DeviceSearch, device_search, waiting_times, waiting_times!
export StreamingState, DistributionAccumulator, pending
export OnlineWaitingTimes, snapshot, status
export WaitingTimeDistribution, empirical_distribution
export Settings, load_settings, threshold_list, effective_config
export CollectionHandle, generate, prepare, run_pipeline, validate
export Collection, load_collection, list_collections, distribution, thresholds,
       summary_table, load_series, export_legacy, source_descriptor

public CLASS_EXACT, CLASS_GAP_CROSSING, CLASS_RIGHT_CENSORED, TIME_UNITS, update!
public narrow_integer, GRID_TOLERANCE, on_grid, suffix_maximum, SearchWorkspace, MaxTree,
       FenwickWorkspace,
       workspace, workspace_bytes, scan_work,
       check_threshold, first_at_least, duration
public support, counts, probabilities, cumulative, survival, nsamples, mean_waiting_time,
       ks_distance
public GAP_KINDS, with_step, sampling_step, record_length, observed_mask, segment_lengths,
       segment_table, describe, SeriesDescription, censoring_histogram, source_summary
public discrete_distribution, plot_series, plot_distribution, plot_values, save_figure,
       figure_theme, decade_ticks, PACKAGE_ROOT
public Synthetic, Backends, Provenance, Config, Naming, Preprocessing, Monitoring, Storage,
       Orchestrator

include("precompile.jl")

end # module
