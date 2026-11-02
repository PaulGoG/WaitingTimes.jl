module WaitingTimesAMDGPUExt

using AMDGPU: AMDGPU, ROCBackend
using WaitingTimes.Backends: Backends

Backends.probe(::Val{:amdgpu}) = AMDGPU.functional() ? ROCBackend() : nothing
function Backends.backend_name(::ROCBackend)
    AMDGPU.functional() || return "AMD ROCm GPU"
    return "AMD ROCm GPU ($(AMDGPU.HIP.name(AMDGPU.device())))"
end
function Backends.device_fingerprint(::ROCBackend)
    AMDGPU.functional() ? sprint(io -> AMDGPU.versioninfo(io)) : ""
end

end # module
