"""
Exact waiting-time distributions of scalar time series for threshold grids.

Given a series ``\\{A_n\\}`` observed at strictly increasing integer times
``\\{t_n\\}`` and a threshold ``\\delta \\ge 0``, the waiting time of index ``n`` is
``\\tau_n = t_m - t_n`` with ``m = \\min\\{m > n : A_m \\ge A_n + \\delta\\}``, the
elapsed time to the first observed value at least ``\\delta`` above ``A_n``.
Values and thresholds live on a decimal integer grid (`digits`), so every
search kernel computes bit-identical results and the naive scan serves as the
permanent correctness oracle.
"""
module WaitingTimes

using DataStructures: BinaryMinHeap
using Dates: DateTime
using DocStringExtensions: TYPEDFIELDS, TYPEDSIGNATURES
using KernelAbstractions: KernelAbstractions, Backend, CPU, @Const, @index, @kernel
using OhMyThreads: tforeach
using Statistics: Statistics

"root directory of the package"
const PACKAGE_ROOT = normpath(joinpath(@__DIR__, ".."))

include("Quantization.jl")
include("Series.jl")
include("Gaps.jl")
include("Kernels.jl")
include("SegmentTree.jl")
include("FenwickSweep.jl")
include("Distribution.jl")
include("Streaming.jl")
include("Synthetic.jl")
include("Backends.jl")
include("DeviceKernels.jl")

"""
$(TYPEDSIGNATURES)

`Distributions.DiscreteNonParametric` view of a distribution; provided by the
Distributions extension (`using Distributions`).
"""
function discrete_distribution end

"""
$(TYPEDSIGNATURES)

Figure of a series against time with gaps shaded; provided by the CairoMakie
extension (`using CairoMakie`).
"""
function plot_series end

"""
$(TYPEDSIGNATURES)

Figure of a distribution (probability mass and survival function on
logarithmic axes); provided by the CairoMakie extension.
"""
function plot_distribution end

"""
$(TYPEDSIGNATURES)

Save a figure with a TOML sidecar of descriptor metadata; provided by the
CairoMakie extension.
"""
function save_figure end

include("Provenance.jl")
include("Config.jl")
include("Naming.jl")
include("Preprocessing.jl")
include("Monitoring.jl")
include("Storage.jl")
include("Orchestrator.jl")

using .Config: Settings, load_settings, threshold_list
using .Orchestrator: CollectionHandle, generate, prepare, run_pipeline, validate
using .Provenance: effective_config

export Threshold, threshold, quantize, format_threshold, parse_threshold
export PreparationStep, PreparationRecord, QuantizedSeries
export detect_gaps, declare_gaps, gap_table, classify, class_counts
export AbstractSearch, NaiveSearch, GuardedSearch, SegmentTreeSearch, FenwickSweep,
       StreamingSearch, DeviceSearch, device_search, waiting_times, waiting_times!
export StreamingState, DistributionAccumulator, update!, pending
export WaitingTimeDistribution, empirical_distribution
export Settings, load_settings, threshold_list, effective_config
export CollectionHandle, generate, prepare, run_pipeline, validate

public CLASS_EXACT, CLASS_GAP_CROSSING, CLASS_RIGHT_CENSORED, TIME_UNITS
public narrow_integer, suffix_maximum, SearchWorkspace, MaxTree, FenwickWorkspace,
       workspace,
       check_threshold, first_at_least, duration, record!
public support, counts, probabilities, cumulative, survival, nsamples, mean_waiting_time
public discrete_distribution, plot_series, plot_distribution, save_figure, PACKAGE_ROOT
public Synthetic, Backends, Provenance, Config, Naming, Preprocessing, Monitoring, Storage,
       Orchestrator

end # module
