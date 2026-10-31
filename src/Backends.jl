"""
Compute-backend registry: probes registered by the package extensions (the
KernelAbstractions extension registers the CPU backend, the CUDA, oneAPI, AMDGPU
and Metal extensions their GPU backends) and the selection of a backend.
"""
module Backends

using DocStringExtensions: TYPEDSIGNATURES

export get_best_backend, to_backend, backend_name
public register_backend!, reclaim_device_memory!, cpu_model, device_fingerprint,
       BACKEND_PROBES, host_backend, load_device_packages, GPU_PACKAGES

"""
Registry of backend probes: `name => probe`, each probe returning a
functional KernelAbstractions backend or `nothing`.
"""
const BACKEND_PROBES = Vector{Pair{Symbol, Function}}()

"""
$(TYPEDSIGNATURES)

Register `probe` under `name` unless the name is taken; called from the
extensions' `__init__`.
"""
function register_backend!(name::Symbol, probe::Function)
    any(p -> first(p) === name, BACKEND_PROBES) || push!(BACKEND_PROBES, name => probe)
    return nothing
end

"CPU backend of the `:cpu` probe, registered by the KernelAbstractions extension"
function cpu_backend()
    for (name, probe) in BACKEND_PROBES
        name === :cpu && return probe()
    end
    throw(ArgumentError(
        "the device kernel needs KernelAbstractions loaded in the session (using KernelAbstractions)",
    ))
end

"""
$(TYPEDSIGNATURES)

Backend selected by `prefer`: `:none` is the CPU backend registered by the
KernelAbstractions extension under `:cpu`, `:auto` the first functional GPU
with that CPU backend as fallback, and a named backend (`:cuda`, `:oneapi`,
`:amdgpu`, `:metal`) is returned only when its package is loaded and its device
is functional; otherwise an `ArgumentError` is thrown, so a run never silently
proceeds on a backend other than the requested one. The CPU backend needs
KernelAbstractions loaded in the session; without it `:none` and a fallback
of `:auto` throw an `ArgumentError`.
"""
function get_best_backend(; prefer::Symbol = :auto)
    prefer === :none && return cpu_backend()
    for (name, probe) in BACKEND_PROBES
        name === :cpu && continue
        (prefer === :auto || prefer === name) || continue
        backend = probe()
        backend !== nothing && return backend
    end
    prefer === :auto && return cpu_backend()
    throw(ArgumentError(
        "GPU backend :$prefer is not available (package not loaded or device not " *
        "functional); registered probes: $(first.(BACKEND_PROBES))",
    ))
end

"GPU package loaded for each named backend of `[algorithm].backend`"
const GPU_PACKAGES = Dict(:cuda => "CUDA", :amdgpu => "AMDGPU", :metal => "Metal",
    :oneapi => "oneAPI")

"""
$(TYPEDSIGNATURES)

Load KernelAbstractions when it is installed in the active environment, then the
GPU packages selected by `prefer`: every installed package of
[`GPU_PACKAGES`](@ref) for `:auto`, the package of a named backend (with a
warning when it is not installed), nothing more for `:none`. Loading them
activates the package extensions that register the backends. Returns the names
of the packages loaded; any other `prefer` throws an `ArgumentError`.
"""
function load_device_packages(prefer::Symbol)
    prefer === :auto || prefer === :none || haskey(GPU_PACKAGES, prefer) ||
        throw(ArgumentError(
            "unknown backend :$prefer; one of :auto, :none, " *
            join((":$k" for k in sort!(collect(keys(GPU_PACKAGES)))), ", "),
        ))
    loaded = Symbol[]
    installed(pkg) = Base.find_package(pkg) !== nothing
    function load!(pkg)
        Base.require(Main, Symbol(pkg))
        push!(loaded, Symbol(pkg))
    end
    installed("KernelAbstractions") && load!("KernelAbstractions")
    if prefer === :auto
        for key in sort!(collect(keys(GPU_PACKAGES)))
            installed(GPU_PACKAGES[key]) && load!(GPU_PACKAGES[key])
        end
    elseif prefer !== :none
        pkg = GPU_PACKAGES[prefer]
        if installed(pkg)
            load!(pkg)
        else
            @warn "backend :$prefer requested but $pkg is not installed in the active environment"
        end
    end
    return loaded
end

"""
    to_backend(data::AbstractArray, backend) -> AbstractArray

Copy of `data` as an array of `backend`; the KernelAbstractions extension adds
the CPU method (`Array`), the GPU extensions their device array types.
"""
function to_backend end

"""
    host_backend(backend)

Whether `backend` is the host (CPU) backend of KernelAbstractions; the
KernelAbstractions extension defines the `true` method, every GPU backend is
`false`.
"""
host_backend(_) = false

"""
$(TYPEDSIGNATURES)

Model string of the first host CPU; empty when `Sys.cpu_info` reports none.
"""
function cpu_model()
    info = Sys.cpu_info()
    return isempty(info) ? "" : strip(info[1].model)
end

"""
$(TYPEDSIGNATURES)

Human-readable name of the backend `b` for provenance. The fallback is the type
name; the extensions name the CPU with its model and a functional CUDA, AMDGPU
or oneAPI device with its device name (Metal without one).
"""
backend_name(b) = string(nameof(typeof(b)))

"""
    reclaim_device_memory!(backend)

Release the cached device memory pools of `backend` (CUDA); a no-op for the
CPU and for backends without a reclaim API.
"""
reclaim_device_memory!(_) = nothing

"""
    device_fingerprint(backend) -> String

Device and runtime report of `backend` for the hardware sidecar; empty for the
CPU and for a device that is not functional.
"""
device_fingerprint(_) = ""

end # module
