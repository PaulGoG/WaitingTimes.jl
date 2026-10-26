# Device search: DeviceSearch, its workspace type and the backend selection; the
# kernel itself lives in ext/WaitingTimesKernelAbstractionsExt.jl.

using .Backends: get_best_backend

"""
    DeviceSearch(backend = get_best_backend(; prefer = :none))

The guarded scan as a KernelAbstractions kernel: one work-item per index scans
forward from its position until the target is reached, after an O(1)
censoring test on the host-computed suffix maxima. Provided by the
KernelAbstractions extension (`using KernelAbstractions`) on its CPU backend
and on every GPU backend registered by the CUDA, oneAPI, AMDGPU or Metal
extension. Results equal [`NaiveSearch`](@ref) bit for bit. Work is that of
the guarded scan ([`scan_work`](@ref) with `guarded = true`); as a reference
kernel it is bounded by `[limits].max_reference_work` before a check is
launched.
"""
struct DeviceSearch{B} <: AbstractSearch
    backend::B
end
DeviceSearch() = DeviceSearch(get_best_backend(; prefer = :none))

# host-side copies of the values, times, suffix maxima and result
function workspace_bytes(::DeviceSearch, s::QuantizedSeries{Tv, Tt}) where {Tv, Tt}
    length(s) * (2 * sizeof(Tv) + 2 * sizeof(Tt))
end

"""
    DeviceWorkspace

Series arrays resident on the device, the suffix maxima and the result
buffer, uploaded once per series and reused across thresholds.

$(TYPEDFIELDS)
"""
struct DeviceWorkspace{Q, T, M, R}
    "values on the device"
    values::Q
    "times on the device"
    times::T
    "suffix maxima on the device"
    suffix::M
    "result buffer on the device"
    result::R
    "number of observations"
    N::Int
end

"""
Device access is serialised: GPU drivers are not reliably safe under
concurrent multi-task launches (observed with Level Zero).
"""
const DEVICE_LOCK = ReentrantLock()

"""
$(TYPEDSIGNATURES)

Device search on the backend selected by `backend` (`:none` for the CPU,
`:auto` for the first functional GPU, or a named backend), following
[`Backends.get_best_backend`](@ref).
"""
device_search(backend::Symbol = :auto) = DeviceSearch(get_best_backend(; prefer = backend))
