module WaitingTimesMetalExt

using Metal: Metal, MetalBackend
using WaitingTimes.Backends: Backends

Backends.probe(::Val{:metal}) = Metal.functional() ? MetalBackend() : nothing
Backends.backend_name(::MetalBackend) = "Apple Metal GPU"
function Backends.device_fingerprint(::MetalBackend)
    Metal.functional() ? sprint(io -> Metal.versioninfo(io)) : ""
end

end # module
