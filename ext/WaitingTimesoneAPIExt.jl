module WaitingTimesoneAPIExt

using oneAPI: oneAPI, oneAPIBackend, oneArray
using WaitingTimes.Backends: Backends

function __init__()
    Backends.register_backend!(:oneapi, () -> oneAPI.functional() ? oneAPIBackend() :
                                              nothing)
end

Backends.to_backend(data::AbstractArray, ::oneAPIBackend) = oneArray(data)
function Backends.backend_name(::oneAPIBackend)
    oneAPI.functional() || return "Intel oneAPI GPU"
    return "Intel oneAPI GPU ($(strip(oneAPI.oneL0.properties(oneAPI.device()).name)))"
end
function Backends.device_fingerprint(::oneAPIBackend)
    oneAPI.functional() ? sprint(io -> oneAPI.versioninfo(io)) : ""
end

end # module
