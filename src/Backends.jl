"""
Compute-backend registry: the multi-threaded CPU backend of KernelAbstractions
plus GPU probes registered by the package extensions (`WaitingTimes{CUDA,
oneAPI,AMDGPU,Metal}Ext`) when the corresponding GPU package is loaded.
"""
module Backends

using DocStringExtensions: TYPEDSIGNATURES
using KernelAbstractions: KernelAbstractions, CPU

export get_best_backend, to_backend, backend_name
public register_backend!, reclaim_device_memory!, cpu_model, device_fingerprint,
       BACKEND_PROBES

"""
Registry of GPU backend probes: `name => probe`, each probe returning a
functional `KernelAbstractions.Backend` or `nothing`.
"""
const BACKEND_PROBES = Vector{Pair{Symbol, Function}}()

"""
$(TYPEDSIGNATURES)

Register a backend probe; called from the extensions' `__init__`.
"""
function register_backend!(name::Symbol, probe::Function)
    any(p -> first(p) === name, BACKEND_PROBES) || push!(BACKEND_PROBES, name => probe)
    return nothing
end

"""
$(TYPEDSIGNATURES)

Backend selected by `prefer`: `:none` is the multi-threaded `CPU()` backend,
`:auto` the first functional GPU with the CPU as fallback, and a named backend
(`:cuda`, `:oneapi`, `:amdgpu`, `:metal`) is returned only when its package is
loaded and its device is functional; otherwise an `ArgumentError` is thrown,
so a run never silently proceeds on a backend other than the requested one.
"""
function get_best_backend(; prefer::Symbol = :auto)
    prefer === :none && return CPU()
    for (name, probe) in BACKEND_PROBES
        (prefer === :auto || prefer === name) || continue
        backend = probe()
        backend !== nothing && return backend
    end
    prefer === :auto && return CPU()
    throw(ArgumentError(
        "GPU backend :$prefer is not available (package not loaded or device not " *
        "functional); registered probes: $(first.(BACKEND_PROBES))",
    ))
end

"""
$(TYPEDSIGNATURES)

Move an array to the backend; the CPU method materialises an `Array`, the
extensions add their device array types.
"""
to_backend(data::AbstractArray, ::CPU) = Array(data)

"host CPU model string, empty when unavailable"
function cpu_model()
    info = Sys.cpu_info()
    return isempty(info) ? "" : strip(info[1].model)
end

"""
$(TYPEDSIGNATURES)

Human-readable backend description carrying the chip model for provenance.
"""
function backend_name(::CPU)
    model = cpu_model()
    return isempty(model) ? "$(Threads.nthreads())-thread CPU" :
           "$(Threads.nthreads())-thread CPU ($model)"
end
backend_name(b) = string(nameof(typeof(b)))

"""
$(TYPEDSIGNATURES)

Release cached device memory pools; a no-op for the CPU and for backends
without a reclaim API.
"""
reclaim_device_memory!(_) = nothing

"""
$(TYPEDSIGNATURES)

Device and runtime report for the hardware sidecar; empty for the CPU.
"""
device_fingerprint(_) = ""

end # module
