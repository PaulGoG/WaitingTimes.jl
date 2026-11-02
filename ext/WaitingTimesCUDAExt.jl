module WaitingTimesCUDAExt

using CUDA: CUDA, CUDABackend
using WaitingTimes.Backends: Backends

Backends.probe(::Val{:cuda}) = CUDA.functional() ? CUDABackend() : nothing
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
