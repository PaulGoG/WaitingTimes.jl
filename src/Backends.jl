"""
Compute backends: the probes the package extensions define (the
KernelAbstractions extension for the CPU, the CUDA, AMDGPU, oneAPI and Metal
extensions for their GPUs) and the selection of a backend.
"""
module Backends

using DocStringExtensions: TYPEDSIGNATURES

export get_best_backend, backend_name
public probe, GPU_PRIORITY, cpu_backend, reclaim_device_memory!, cpu_model,
       device_fingerprint, host_backend, load_device_packages, GPU_PACKAGES

"GPU backends tried by `:auto`, in order of preference"
const GPU_PRIORITY = (:cuda, :amdgpu, :oneapi, :metal)

"""
    probe(::Val{name}) -> backend or nothing

Functional KernelAbstractions backend of the vendor `name` (`:cuda`,
`:amdgpu`, `:oneapi`, `:metal`) or the CPU (`:cpu`); `nothing` when the
package is not loaded or its device is not functional. The package extensions
define the methods; without them every name probes to `nothing`.
"""
probe(::Val) = nothing

"CPU backend of the KernelAbstractions extension"
function cpu_backend()
    backend = probe(Val(:cpu))
    backend === nothing && throw(ArgumentError(
        "the device kernel needs KernelAbstractions loaded in the session (using KernelAbstractions)",
    ))
    return backend
end

"""
$(TYPEDSIGNATURES)

Backend selected by `prefer`: `:none` is the CPU backend of the
KernelAbstractions extension; `:auto` is the first functional GPU in the order
of [`GPU_PRIORITY`](@ref), whatever the order in which the GPU packages were
loaded, with the CPU backend as fallback; a named backend (`:cuda`, `:amdgpu`,
`:oneapi`, `:metal`) is returned only when its package is loaded and its
device is functional, otherwise an `ArgumentError` is thrown, so a run never
silently proceeds on a backend other than the requested one. Without
KernelAbstractions loaded, `:none` and the fallback of `:auto` throw an
`ArgumentError`.
"""
function get_best_backend(; prefer::Symbol = :auto)
    prefer === :none && return cpu_backend()
    if prefer === :auto
        for name in GPU_PRIORITY
            backend = probe(Val(name))
            backend === nothing || return backend
        end
        return cpu_backend()
    end
    prefer in GPU_PRIORITY || throw(ArgumentError(
        "unknown backend :$prefer; one of :none, :auto, " *
        join((":$k" for k in GPU_PRIORITY), ", "),
    ))
    backend = probe(Val(prefer))
    backend === nothing && throw(ArgumentError(
        "GPU backend :$prefer is not available (package not loaded or device not functional)",
    ))
    return backend
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
activates the package extensions that define the probes. Returns the names of
the packages loaded; any other `prefer` throws an `ArgumentError`.
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
