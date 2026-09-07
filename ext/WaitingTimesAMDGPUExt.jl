module WaitingTimesAMDGPUExt

using AMDGPU: AMDGPU, ROCBackend, ROCArray
using WaitingTimes.Backends: Backends

function __init__()
    Backends.register_backend!(:amdgpu, () -> AMDGPU.functional() ? ROCBackend() : nothing)
end

Backends.to_backend(data::AbstractArray, ::ROCBackend) = ROCArray(data)
function Backends.backend_name(::ROCBackend)
    AMDGPU.functional() || return "AMD ROCm GPU"
    return "AMD ROCm GPU ($(AMDGPU.HIP.name(AMDGPU.device())))"
end
function Backends.device_fingerprint(::ROCBackend)
    AMDGPU.functional() ? sprint(io -> AMDGPU.versioninfo(io)) : ""
end

end # module
