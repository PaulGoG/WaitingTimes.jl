"""
Identity and provenance: effective configurations with overlays, canonical
hashing, artefact identifiers, git and hardware fingerprints, metadata files
and backup-before-overwrite semantics.
"""
module Provenance

using DocStringExtensions: TYPEDSIGNATURES
using Dates: DateTime, Dates, UTC, now
using DrWatson: gitdescribe
using InteractiveUtils: versioninfo
using LinearAlgebra: BLAS
using SHA: sha256
using TOML: TOML
using ..WaitingTimes: PreparationRecord, PreparationStep

export effective_config, canonical_toml, content_hash, artefact_id, file_sha256, slugify,
       git_state, hardware_fingerprint, write_hardware_fingerprint, backup_existing!,
       session_id, read_toml, write_toml, toml_ready, record_to_dict, dict_to_record

"top-level key naming the base file an overlay configuration is merged onto"
const BASE_CONFIG_KEY = "base_config"

"""
$(TYPEDSIGNATURES)

Parsed configuration with its base file resolved: a top-level
`base_config = "file.toml"` (relative to the overlay's directory) names a base
whose tables are deep-merged beneath the overlay's, one level only. The key is
stripped, so the result is self-contained.
"""
function effective_config(config_path::AbstractString)
    config = TOML.parsefile(config_path)
    haskey(config, BASE_CONFIG_KEY) || return config
    base_rel = pop!(config, BASE_CONFIG_KEY)
    base_rel isa AbstractString ||
        throw(ArgumentError("$BASE_CONFIG_KEY in $config_path must be a file path"))
    base_path = normpath(joinpath(dirname(abspath(config_path)), base_rel))
    isfile(base_path) ||
        throw(ArgumentError("$BASE_CONFIG_KEY of $config_path names a missing file: $base_path"))
    base = TOML.parsefile(base_path)
    haskey(base, BASE_CONFIG_KEY) && throw(ArgumentError(
        "base configuration $base_path declares $BASE_CONFIG_KEY itself; one overlay level only",
    ))
    return merge_config(base, config)
end

"deep merge of `overlay` into `base`: sub-tables recurse, everything else is replaced"
function merge_config(base::AbstractDict, overlay::AbstractDict)
    merged = Dict{String, Any}(base)
    for (key, value) in overlay
        merged[key] = (value isa AbstractDict &&
                       get(merged, key, nothing) isa AbstractDict) ?
                      merge_config(merged[key], value) : value
    end
    return merged
end

"""
$(TYPEDSIGNATURES)

Convert a value into something `TOML.print` accepts: symbols and `nothing`
become strings (`""` for `nothing`), tuples become vectors, dictionaries and
vectors are converted recursively.
"""
toml_ready(x::AbstractDict) = Dict{String, Any}(String(k) => toml_ready(v) for (k, v) in x)
toml_ready(x::Union{AbstractVector, Tuple}) = Any[toml_ready(v) for v in x]
toml_ready(x::Symbol) = String(x)
toml_ready(::Nothing) = ""
toml_ready(x::Union{AbstractString, Integer, AbstractFloat, Bool, DateTime}) = x
toml_ready(x::NamedTuple) = toml_ready(Dict(pairs(x)))
toml_ready(x) = string(x)

"""
$(TYPEDSIGNATURES)

Canonical TOML serialisation (keys sorted, values only) used for hashing.
"""
canonical_toml(x::AbstractDict) = sprint(io -> TOML.print(io, toml_ready(x); sorted = true))

"""
$(TYPEDSIGNATURES)

SHA-256 hex digest of the canonical serialisation of `x`.
"""
content_hash(x::AbstractDict) = bytes2hex(sha256(canonical_toml(x)))

"""
$(TYPEDSIGNATURES)

Artefact identifier `<kind>-<slug>-<hash8>` from the identity fields.
"""
function artefact_id(kind::AbstractString, slug::AbstractString, identity::AbstractDict)
    string(kind, '-', slugify(slug), '-', first(content_hash(identity), 8))
end

"""
$(TYPEDSIGNATURES)

Filesystem-safe slug: every character outside `A-Za-z0-9_+-.` becomes `_`,
runs of `_` collapse, leading and trailing `_` are removed.
"""
function slugify(text::AbstractString)
    s = replace(String(text), r"[^A-Za-z0-9_+\-.]" => "_")
    s = replace(s, r"_+" => "_")
    s = strip(s, '_')
    isempty(s) && throw(ArgumentError("slug of $(repr(text)) is empty"))
    return s
end

"""
$(TYPEDSIGNATURES)

SHA-256 hex digest of a file.
"""
file_sha256(path::AbstractString) = open(io -> bytes2hex(sha256(io)), path)

"""
$(TYPEDSIGNATURES)

`git describe`-style state of the repository at `root` (commit, tags, dirty
flag) via DrWatson, or `"unknown"` outside a repository.
"""
function git_state(root::AbstractString)
    desc = try
        gitdescribe(root)
    catch
        nothing
    end
    return desc === nothing ? "unknown" : String(desc)
end

"""
$(TYPEDSIGNATURES)

Platform fingerprint as a dictionary: host name, CPU model, logical cores,
Julia threads, total memory, Julia version, operating system, BLAS threads.
"""
function hardware_fingerprint()
    info = Sys.cpu_info()
    cpu = isempty(info) ? "" : strip(info[1].model)
    return Dict{String, Any}(
        "hostname" => gethostname(),
        "cpu" => cpu,
        "logical_cores" => Sys.CPU_THREADS,
        "threads" => Threads.nthreads(),
        "memory_bytes" => Int(Sys.total_memory()),
        "julia" => string(VERSION),
        "os" => string(Sys.KERNEL, ' ', Sys.MACHINE),
        "blas_threads" => BLAS.get_num_threads()
    )
end

"""
$(TYPEDSIGNATURES)

Write the platform fingerprint text file: `versioninfo`, host totals and,
when given, the device report of a GPU backend.
"""
function write_hardware_fingerprint(path::AbstractString; device_report::AbstractString = "")
    open(path, "w") do io
        versioninfo(io)
        println(io)
        println(io, "Logical CPU threads: ", Sys.CPU_THREADS)
        println(io, "Total memory: ", round(Sys.total_memory() / 2^30; digits = 1), " GiB")
        println(io, "BLAS threads: ", BLAS.get_num_threads())
        if !isempty(device_report)
            println(io)
            println(io, "── GPU backend ──")
            print(io, device_report)
        end
    end
    return path
end

"""
$(TYPEDSIGNATURES)

Move an existing file to `<name>#<k><ext>` with the smallest free `k` before
the caller writes a new one; returns `path`.
"""
function backup_existing!(path::AbstractString)
    if isfile(path)
        stem, ext = splitext(path)
        k = 1
        while isfile("$(stem)#$(k)$(ext)")
            k += 1
        end
        mv(path, "$(stem)#$(k)$(ext)")
    end
    return path
end

"""
$(TYPEDSIGNATURES)

Session identifier from the UTC wall clock and the first characters of the
git state.
"""
function session_id(git::AbstractString = "unknown")
    stamp = Dates.format(now(UTC), "yyyymmddTHHMMSS")
    tag = slugify(first(git, 12))
    return string(stamp, '_', tag)
end

"parse a TOML file into a dictionary"
read_toml(path::AbstractString) = TOML.parsefile(path)

"""
$(TYPEDSIGNATURES)

Write `x` as TOML to `path` (keys sorted), converting values with
[`toml_ready`](@ref).
"""
function write_toml(path::AbstractString, x::AbstractDict)
    open(path, "w") do io
        TOML.print(io, toml_ready(x); sorted = true)
    end
    return path
end

"""
$(TYPEDSIGNATURES)

Dictionary form of a preparation record, for metadata files.
"""
function record_to_dict(record::PreparationRecord)
    Dict{String, Any}(
        "source" => record.source,
        "source_sha256" => record.source_sha256,
        "steps" => Any[Dict{String, Any}("op" => String(step.op),
                "parameters" => toml_ready(step.parameters),
                "summary" => toml_ready(step.summary)) for step in record.steps]
    )
end

"""
$(TYPEDSIGNATURES)

Preparation record from its dictionary form.
"""
function dict_to_record(d::AbstractDict)
    record = PreparationRecord(get(d, "source", ""); sha256 = get(d, "source_sha256", ""))
    for step in get(d, "steps", Any[])
        push!(record.steps,
            PreparationStep(Symbol(step["op"]),
                Dict{String, Any}(get(step, "parameters", Dict())),
                Dict{String, Any}(get(step, "summary", Dict()))))
    end
    return record
end

end # module
