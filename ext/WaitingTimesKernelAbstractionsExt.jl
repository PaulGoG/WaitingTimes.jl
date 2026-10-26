# Device kernel of DeviceSearch: the guarded scan as a KernelAbstractions kernel,
# with the CPU backend probe and the CPU methods of the backend registry.
module WaitingTimesKernelAbstractionsExt

using KernelAbstractions: KernelAbstractions, Backend, CPU, @Const, @index, @kernel
using WaitingTimes: WaitingTimes, DeviceSearch, DeviceWorkspace, QuantizedSeries, Threshold,
                    check_threshold, suffix_maximum
using WaitingTimes.Backends: Backends

function __init__()
    Backends.register_backend!(:cpu, () -> CPU())
end

Backends.to_backend(data::AbstractArray, ::CPU) = Array(data)
Backends.host_backend(::CPU) = true
function Backends.backend_name(::CPU)
    model = Backends.cpu_model()
    return isempty(model) ? "CPU" : "CPU ($model)"
end

function WaitingTimes.workspace(alg::DeviceSearch{<:Backend},
        s::QuantizedSeries{Tv, Tt}) where {Tv, Tt}
    N = length(s)
    return DeviceWorkspace(
        Backends.to_backend(s.values, alg.backend), Backends.to_backend(s.times, alg.backend),
        Backends.to_backend(suffix_maximum(s.values), alg.backend),
        fill!(KernelAbstractions.allocate(alg.backend, Tt, N), zero(Tt)), N)
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

function WaitingTimes.waiting_times!(τ::AbstractVector{Tt}, s::QuantizedSeries{Tv, Tt},
        δ::Threshold, alg::DeviceSearch{<:Backend};
        workspace::Union{Nothing, DeviceWorkspace} = nothing) where {Tv, Tt}
    N = length(s)
    length(τ) == N || throw(DimensionMismatch("τ has length $(length(τ)), series has $N"))
    d = check_threshold(s, δ)
    ws = workspace === nothing ? WaitingTimes.workspace(alg, s) : workspace
    ws.N == N || throw(DimensionMismatch("workspace was built for another series"))
    lock(WaitingTimes.DEVICE_LOCK) do
        kernel = waiting_times_kernel!(alg.backend)
        kernel(ws.result, ws.values, ws.times, ws.suffix, d, N; ndrange = N)
        KernelAbstractions.synchronize(alg.backend)
        copyto!(τ, Array(ws.result))
    end
    return τ
end

end # module
