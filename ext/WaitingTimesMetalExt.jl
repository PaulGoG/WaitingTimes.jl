module WaitingTimesMetalExt

using Metal: Metal, MetalBackend, MtlArray
using WaitingTimes.Backends: Backends

function __init__()
    Backends.register_backend!(:metal, () -> Metal.functional() ? MetalBackend() : nothing)
end

Backends.to_backend(data::AbstractArray, ::MetalBackend) = MtlArray(data)
Backends.backend_name(::MetalBackend) = "Apple Metal GPU"
function Backends.device_fingerprint(::MetalBackend)
    Metal.functional() ? sprint(io -> Metal.versioninfo(io)) : ""
end

end # module
