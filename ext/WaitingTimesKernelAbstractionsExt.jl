# Device kernel of DeviceSearch: the guarded scan as a KernelAbstractions kernel,
# with the CPU backend probe and the CPU methods of the backend module.
module WaitingTimesKernelAbstractionsExt

using KernelAbstractions: KernelAbstractions, Backend, CPU, @Const, @index, @kernel
using WaitingTimes: WaitingTimes, DeviceSearch, DeviceWorkspace, QuantizedSeries, Threshold,
                    check_threshold, suffix_maximum
using WaitingTimes.Backends: Backends

Backends.probe(::Val{:cpu}) = CPU()
Backends.host_backend(::CPU) = true
function Backends.backend_name(::CPU)
    model = Backends.cpu_model()
    return isempty(model) ? "CPU" : "CPU ($model)"
end

function WaitingTimes.workspace(alg::DeviceSearch{<:Backend},
        s::QuantizedSeries{Tv, Tt}) where {Tv, Tt}
    N = length(s)
    upload(x) = copyto!(KernelAbstractions.allocate(alg.backend, eltype(x), length(x)), x)
    return DeviceWorkspace(
        upload(s.values), upload(s.times), upload(suffix_maximum(s.values)),
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
        copyto!(τ, ws.result)
    end
    return τ
end

end # module
