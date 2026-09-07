module WaitingTimesCUDAExt

using CUDA: CUDA, CUDABackend, CuArray
using WaitingTimes.Backends: Backends

function __init__()
    Backends.register_backend!(:cuda, () -> CUDA.functional() ? CUDABackend() : nothing)
end

Backends.to_backend(data::AbstractArray, ::CUDABackend) = CuArray(data)
function Backends.backend_name(::CUDABackend)
    CUDA.functional() || return "NVIDIA CUDA GPU"
    return "NVIDIA CUDA GPU ($(CUDA.name(CUDA.device())))"
end
function Backends.device_fingerprint(::CUDABackend)
    CUDA.functional() ? sprint(io -> CUDA.versioninfo(io)) : ""
end
function Backends.reclaim_device_memory!(::CUDABackend)
    (CUDA.functional() && CUDA.reclaim(); nothing)
end

end # module
