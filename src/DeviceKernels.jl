# Device search: the naive scan as a KernelAbstractions kernel, one work-item
# per index, runnable on the multi-threaded CPU backend and on every GPU
# backend registered by the extensions.

using .Backends: get_best_backend, to_backend

"""
    DeviceSearch(backend = CPU())

The naive scan as a KernelAbstractions kernel: one work-item per index scans
forward from its position until the target is reached, after an O(1)
censoring test on the host-computed suffix maxima. The CPU backend is always
available; GPU backends come from loading CUDA, oneAPI, AMDGPU or Metal.
Results equal [`NaiveSearch`](@ref) bit for bit. Work is ``O(\\sum_n \\tau_n)``,
so the pipeline bounds it with `[limits].max_naive_work` before launching.
"""
struct DeviceSearch{B <: Backend} <: AbstractSearch
    backend::B
end
DeviceSearch() = DeviceSearch(CPU())

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

function workspace(alg::DeviceSearch, s::QuantizedSeries{Tv, Tt}) where {Tv, Tt}
    N = length(s)
    return DeviceWorkspace(
        to_backend(s.values, alg.backend), to_backend(s.times, alg.backend),
        to_backend(suffix_maximum(s.values), alg.backend),
        KernelAbstractions.zeros(alg.backend, Tt, N), N)
end

@kernel function waiting_times_kernel!(τ, @Const(q), @Const(t), @Const(M), d, N::Int)
    i = @index(Global, Linear)
    @inbounds if i < N
        target = q[i] + d
        if target > M[i + 1]
            τ[i] = zero(eltype(τ))
        else
            j = i + 1
            while q[j] < target
                j += 1
            end
            τ[i] = t[j] - t[i]
        end
    elseif i == N
        τ[i] = zero(eltype(τ))
    end
end

"""
Device access is serialised: GPU drivers are not reliably safe under
concurrent multi-task launches (observed with Level Zero).
"""
const DEVICE_LOCK = ReentrantLock()

function waiting_times!(τ::AbstractVector{Tt}, s::QuantizedSeries{Tv, Tt}, δ::Threshold,
        alg::DeviceSearch; workspace::Union{Nothing, DeviceWorkspace} = nothing) where {
        Tv, Tt}
    N = length(s)
    length(τ) == N || throw(DimensionMismatch("τ has length $(length(τ)), series has $N"))
    d = check_threshold(s, δ)
    ws = workspace === nothing ? WaitingTimes.workspace(alg, s) : workspace
    ws.N == N || throw(DimensionMismatch("workspace was built for another series"))
    lock(DEVICE_LOCK) do
        kernel = waiting_times_kernel!(alg.backend)
        kernel(ws.result, ws.values, ws.times, ws.suffix, d, N; ndrange = N)
        KernelAbstractions.synchronize(alg.backend)
        copyto!(τ, Array(ws.result))
    end
    return τ
end

"""
$(TYPEDSIGNATURES)

Device search on the backend selected by `backend` (`:none` for the CPU,
`:auto` for the first functional GPU, or a named backend), following
[`Backends.get_best_backend`](@ref).
"""
device_search(backend::Symbol = :auto) = DeviceSearch(get_best_backend(; prefer = backend))
