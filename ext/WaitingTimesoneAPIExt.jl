module WaitingTimesoneAPIExt

using oneAPI: oneAPI, oneAPIBackend
using WaitingTimes.Backends: Backends

Backends.probe(::Val{:oneapi}) = oneAPI.functional() ? oneAPIBackend() : nothing
function Backends.backend_name(::oneAPIBackend)
    oneAPI.functional() || return "Intel oneAPI GPU"
    return "Intel oneAPI GPU ($(strip(oneAPI.oneL0.properties(oneAPI.device()).name)))"
end
function Backends.device_fingerprint(::oneAPIBackend)
    oneAPI.functional() ? sprint(io -> oneAPI.versioninfo(io)) : ""
end

end # module
