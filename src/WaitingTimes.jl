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
using OhMyThreads: tforeach
using Statistics: Statistics

include("Quantization.jl")
include("Series.jl")
include("Gaps.jl")
include("Kernels.jl")
include("SegmentTree.jl")
include("FenwickSweep.jl")
include("Distribution.jl")
include("Streaming.jl")
include("Synthetic.jl")

export Threshold, threshold, quantize, format_threshold, parse_threshold
export PreparationStep, PreparationRecord, QuantizedSeries
export detect_gaps, declare_gaps, gap_table, classify, class_counts
export AbstractSearch, NaiveSearch, GuardedSearch, SegmentTreeSearch, FenwickSweep,
       StreamingSearch, waiting_times, waiting_times!
export StreamingState, DistributionAccumulator, update!, pending
export WaitingTimeDistribution, empirical_distribution

public CLASS_EXACT, CLASS_GAP_CROSSING, CLASS_RIGHT_CENSORED, TIME_UNITS
public narrow_integer, suffix_maximum, SearchWorkspace, MaxTree, FenwickWorkspace,
       workspace,
       check_threshold, first_at_least, duration
public support, counts, probabilities, cumulative, survival, nsamples, mean_waiting_time
public Synthetic

end # module
