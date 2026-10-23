"""
Identity and provenance: effective configurations with overlays, canonical
hashing, artefact identifiers, source identities of package code, git and
hardware fingerprints, metadata files and backup-before-overwrite semantics.
"""
module Provenance

using DocStringExtensions: TYPEDSIGNATURES
using Dates: DateTime, Dates, UTC, now
using DrWatson: gitdescribe
using InteractiveUtils: versioninfo
using LinearAlgebra: BLAS
using SHA: SHA1_CTX, digest!, sha1, sha256, update!
using TOML: TOML
using ..WaitingTimes: PACKAGE_ROOT, PreparationRecord, PreparationStep

export effective_config, canonical_toml, content_hash, artefact_id, file_sha256, slugify,
       git_state, hardware_fingerprint, write_hardware_fingerprint, backup_existing!,
       session_id, read_toml, write_toml, toml_ready, record_to_dict, dict_to_record,
       tree_hash, active_manifest, manifest_entry, source_identity, package_identity,
       source_summary, MINIMUM_PRODUCER_VERSION

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

# --- source identity -----------------------------------------------------------

"read buffer of the streamed blob hash"
const BLOB_CHUNK_BYTES = 1 << 16

"""
$(TYPEDSIGNATURES)

Git tree-object SHA-1 (40 lowercase hexadecimal digits) of the content of
`dir`: identical to `git rev-parse HEAD^{tree}` of a clean checkout of the same
content and to the `git-tree-sha1` Pkg records for an installed copy.

Regular files are blobs of mode `100644`, or `100755` when the owner execute
bit is set (the bit git and Pkg consult); symbolic links are blobs of mode
`120000` holding the link target. `.git` is skipped at every level, the names
in `exclude` at the top level only, and directories left without files are
omitted, as git records no empty trees. Sockets, FIFOs and device files are
ignored. A directory without files hashes to the empty tree
`4b825dc642cb6eb9a060e54bf8d69288fbee4904`.

# Example
```julia
tree_hash(pkgdir(WaitingTimes))                 # a top-level data/ left out
tree_hash(pkgdir(WaitingTimes); exclude = ())   # everything but .git
```
"""
function tree_hash(dir::AbstractString; exclude = ("data",))
    isdir(dir) || throw(ArgumentError("not a directory: $dir"))
    digest = tree_digest(dir, exclude)
    return bytes2hex(digest === nothing ? sha1("tree 0\0") : digest)
end

"raw SHA-1 of the tree object of `dir`, or `nothing` when no file remains after exclusion"
function tree_digest(dir::AbstractString, exclude)
    # (sort key, entry header "<mode> <name>\0", raw digest of the child object)
    entries = Tuple{String, String, Vector{UInt8}}[]
    for name in readdir(dir; sort = false)
        (name == ".git" || name in exclude) && continue
        path = joinpath(dir, name)
        if islink(path)
            target = readlink(path)
            blob = sha1("blob $(sizeof(target))\0$target")
            push!(entries, (name, "120000 $name\0", blob))
        elseif isdir(path)
            digest = tree_digest(path, ())
            digest === nothing || push!(entries, (name * "/", "40000 $name\0", digest))
        elseif isfile(path)
            mode = owner_executable(path) ? "100755" : "100644"
            push!(entries, (name, "$mode $name\0", blob_digest(path)))
        end
    end
    isempty(entries) && return nothing
    # git orders entries bytewise by name, a tree's name taken with a trailing '/';
    # String comparison in Julia is bytewise
    sort!(entries; by = first)
    ctx = SHA1_CTX()
    update!(ctx, codeunits("tree $(sum(e -> sizeof(e[2]) + length(e[3]), entries))\0"))
    for (_, header, digest) in entries
        update!(ctx, codeunits(header))
        update!(ctx, digest)
    end
    return digest!(ctx)
end

"executable bit as git and Pkg read it: owner bit on POSIX, `Sys.isexecutable` on Windows"
function owner_executable(path::AbstractString)
    @static Sys.iswindows() ? Sys.isexecutable(path) : !iszero(filemode(path) & 0o100)
end

"raw SHA-1 of the blob object of a regular file, streamed in chunks"
function blob_digest(path::AbstractString)
    ctx = SHA1_CTX()
    update!(ctx, codeunits("blob $(filesize(path))\0"))
    buffer = Vector{UInt8}(undef, BLOB_CHUNK_BYTES)
    open(path) do io
        while !eof(io)
            n = readbytes!(io, buffer)
            update!(ctx, view(buffer, 1:n))
        end
    end
    return digest!(ctx)
end

"manifest file names in the order code loading tries them"
const MANIFEST_NAMES = ("JuliaManifest-v$(VERSION.major).$(VERSION.minor).toml",
    "Manifest-v$(VERSION.major).$(VERSION.minor).toml",
    "JuliaManifest.toml", "Manifest.toml")

"project file names in the order code loading tries them"
const PROJECT_NAMES = ("JuliaProject.toml", "Project.toml")

"parsed TOML file, or an empty dictionary when the file is absent or malformed"
function parse_toml_or_empty(path::AbstractString)
    isfile(path) || return Dict{String, Any}()
    parsed = TOML.tryparsefile(path)
    return parsed isa AbstractDict ? parsed : Dict{String, Any}()
end

"""
$(TYPEDSIGNATURES)

Path of the manifest that code loading pairs with the project file `project`,
by default the active project, or `nothing` when there is none.

The rules are those of `Base` code loading: when the project is a member of a
workspace (a project file in a parent directory whose `[workspace] projects`
lists the project's directory), the manifest of the workspace root, resolved
recursively; otherwise the file named by a top-level `manifest` key (relative
to the project's directory) when it exists, else the first existing of
`JuliaManifest-vX.Y.toml`, `Manifest-vX.Y.toml`, `JuliaManifest.toml` and
`Manifest.toml` for the running Julia version `X.Y`. The search for a
workspace root stops at the home directory when the project lies below it.
"""
function active_manifest(project::Union{Nothing, AbstractString} = Base.active_project())
    (project === nothing || !isfile(project)) && return nothing
    root = workspace_root(project)
    root === nothing || return active_manifest(root)
    dir = dirname(abspath(project))
    explicit = get(parse_toml_or_empty(project), "manifest", nothing)
    if explicit isa AbstractString
        path = normpath(joinpath(dir, explicit))
        isfile(path) && return path
    end
    for name in MANIFEST_NAMES
        path = joinpath(dir, name)
        isfile(path) && return path
    end
    return nothing
end

"project file of the workspace listing the directory of `project` as a member, or `nothing`"
function workspace_root(project::AbstractString)
    home = abspath(homedir())
    project_dir = dirname(abspath(project))
    below_home = startswith(project_dir, home)
    current = project_dir
    while true
        parent = dirname(current)
        (parent == current || (below_home && !startswith(parent, home))) && return nothing
        for name in PROJECT_NAMES
            candidate = joinpath(parent, name)
            isfile(candidate) || continue
            workspace = get(parse_toml_or_empty(candidate), "workspace", nothing)
            workspace isa AbstractDict || break
            members = get(workspace, "projects", nothing)
            if members isa AbstractVector
                for member in members
                    member isa AbstractString || continue
                    path = joinpath(parent, member)
                    isdir(path) && samefile(path, project_dir) && return candidate
                end
            end
            break
        end
        current = parent
    end
end

"""
$(TYPEDSIGNATURES)

Entry `[[deps.<Name>]]` of the version-2 manifest at `manifest_path` whose
`uuid` equals `uuid`, or `nothing` when the file is absent, unparsable, not a
version-2 manifest, or holds no such entry.
"""
function manifest_entry(manifest_path::AbstractString, uuid::Base.UUID)
    manifest = parse_toml_or_empty(manifest_path)
    startswith(string(get(manifest, "manifest_format", "")), "2.") || return nothing
    deps = get(manifest, "deps", nothing)
    deps isa AbstractDict || return nothing
    key = string(uuid)
    for entries in values(deps)
        entries isa AbstractVector || continue
        for entry in entries
            entry isa AbstractDict && get(entry, "uuid", nothing) == key &&
                return Dict{String, Any}(entry)
        end
    end
    return nothing
end

"variables that would make git select a repository other than the one `-C` names"
const GIT_REPOSITORY_VARIABLES = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR")

"""
standard output (trailing newline removed) of `git -C dir args...`, or `nothing`
when the git executable is absent, cannot be started or exits with an error
"""
function git_output(dir::AbstractString, args::AbstractString...)
    git = Sys.which("git")
    git === nothing && return nothing
    env = filter(kv -> !(first(kv) in GIT_REPOSITORY_VARIABLES), ENV)
    env["GIT_OPTIONAL_LOCKS"] = "0"     # status queries never write the index
    cmd = setenv(ignorestatus(`$git -C $dir $args`), env)
    out = IOBuffer()
    process = try
        run(pipeline(cmd; stdout = out, stderr = devnull))
    catch err
        # a spawn failure is an absent git for the purpose of identification
        err isa InterruptException && rethrow()
        return nothing
    end
    success(process) || return nothing
    return chomp(String(take!(out)))
end

"identity record with the six fields of [`source_identity`](@ref)"
function identity_record(source::AbstractString, tree::AbstractString;
        commit::AbstractString = "", dirty::Bool = false,
        url::AbstractString = "", rev::AbstractString = "")
    Dict{String, Any}("identity_source" => String(source),
        "git_tree_sha1" => String(tree),
        "git_commit" => String(commit),
        "git_dirty" => dirty,
        "repo_url" => String(url),
        "repo_rev" => String(rev))
end

"identity of `dir` as the top level of a git work tree, or `nothing`"
function work_tree_identity(dir::AbstractString)
    top = git_output(dir, "rev-parse", "--show-toplevel")
    (top === nothing || !isdir(top) || !samefile(top, dir)) && return nothing
    commit = git_output(dir, "rev-parse", "--verify", "HEAD")
    tree = git_output(dir, "rev-parse", "--verify", "HEAD^{tree}")
    status = git_output(dir, "status", "--porcelain", "--untracked-files=no")
    (commit === nothing || tree === nothing || status === nothing) && return nothing
    (isempty(commit) || isempty(tree)) && return nothing
    return identity_record("work_tree", tree; commit, dirty = !isempty(status))
end

"identity of `dir` as the installed copy recorded under `uuid` in `manifest`, or `nothing`"
function manifest_identity(dir::AbstractString, uuid::Union{Nothing, Base.UUID},
        manifest::Union{Nothing, AbstractString})
    (uuid === nothing || manifest === nothing) && return nothing
    entry = manifest_entry(manifest, uuid)
    (entry === nothing || haskey(entry, "path")) && return nothing
    recorded = get(entry, "git-tree-sha1", nothing)
    (recorded isa AbstractString && !isempty(recorded)) || return nothing
    recorded = lowercase(recorded)
    url = get(entry, "repo-url", "")
    rev = get(entry, "repo-rev", "")
    url = url isa AbstractString ? url : ""
    rev = rev isa AbstractString ? rev : ""
    commit = occursin(r"^[0-9a-fA-F]{40}$", rev) ? lowercase(rev) : ""
    # a package that ships a top-level data/ directory is hashed whole as well
    clean = tree_hash(dir) == recorded ||
            (isdir(joinpath(dir, "data")) && tree_hash(dir; exclude = ()) == recorded)
    return identity_record("manifest", recorded; commit, dirty = !clean, url, rev)
end

"""
$(TYPEDSIGNATURES)

Identity of the source code in the package directory `dir`, valid whether the
code runs from a git checkout or from a copy installed by Pkg. Returns a
dictionary with six fields:

| Field | Content |
|:----- |:------- |
| `identity_source` | `"work_tree"` (`dir` is the top level of a git work tree), `"manifest"` (an installed copy, matched by `uuid` to its entry in `manifest`) or `"directory"` (neither; the directory content alone) |
| `git_tree_sha1` | `HEAD^{tree}` of the checkout, the `git-tree-sha1` of the manifest entry, or [`tree_hash`](@ref) of `dir`; never empty |
| `git_commit` | `HEAD` of the checkout; for an installed copy the `repo-rev` of the manifest entry when it is a full 40-digit commit hash; `""` otherwise |
| `git_dirty` | uncommitted changes to tracked files of the checkout, or an installed copy whose tree hash differs from the recorded one; `false` for `"directory"` |
| `repo_url`, `repo_rev` | `repo-url` and `repo-rev` of the manifest entry of a copy added by URL; `""` otherwise |

The modes are tried in the order above. Git is consulted only when `dir` is
itself the top level of a work tree, so a package directory inside another
repository (a version-controlled depot, say) does not inherit that
repository's commit; an absent or failing git executable falls through to
the next mode. A manifest entry with a `path` (a developed package) or
without `git-tree-sha1` does not identify an installed copy. Environmental
failures never raise; an `ArgumentError` is thrown only when `dir` is not a
directory.

# Example
```julia
uuid = Base.UUID("78cbc771-1cb5-4db9-b01d-2cca60acb935")
source_identity(pkgdir(WaitingTimes); uuid)["git_tree_sha1"]
```
"""
function source_identity(dir::AbstractString; uuid::Union{Nothing, Base.UUID} = nothing,
        manifest::Union{Nothing, AbstractString} = active_manifest())
    isdir(dir) || throw(ArgumentError("not a directory: $dir"))
    identity = work_tree_identity(dir)
    identity === nothing || return identity
    identity = manifest_identity(dir, uuid, manifest)
    identity === nothing || return identity
    return identity_record("directory", tree_hash(dir))
end

"""
$(TYPEDSIGNATURES)

[`source_identity`](@ref) of the loaded WaitingTimes code, matched against the
active manifest by the package UUID.
"""
function package_identity()
    project = parse_toml_or_empty(joinpath(PACKAGE_ROOT, "Project.toml"))
    id = get(project, "uuid", nothing)
    uuid = id isa AbstractString ? tryparse(Base.UUID, id) : nothing
    return source_identity(PACKAGE_ROOT; uuid)
end

"""
Producers whose source descriptors are recognised, with the oldest producer
version whose file contract this version of WaitingTimes reads: the
DeepSpaceTelemetry.jl run descriptor (`descriptor.toml`, schema
`deepspacetelemetry-run/1`, written since 2.5.0) and the MarketTickStreamer.jl
session sidecar (`<session>.meta.toml`, with the tick files read by
`format = :tick` since 0.3.0; the file contract is fixed by 1.0.0).
"""
const MINIMUM_PRODUCER_VERSION = Dict("DeepSpaceTelemetry" => v"2.5.0",
    "MarketTickStreamer" => v"0.3.0")

"a recorded commit, with the placeholders some producers write for none mapped to empty"
commit_or_empty(x) = (c = string(something(x, "")); c in ("unknown", "nothing") ? "" : c)

"""
$(TYPEDSIGNATURES)

Normalised identity of a source descriptor, whatever its producer: `producer`
(package name, empty when not stated), `producer_version`, `git_tree_sha1`
(the authoritative code identity, empty when the producer does not record it,
as DeepSpaceTelemetry before 2.6.1 and MarketTickStreamer), `git_dirty`,
`git_commit` (empty unless the producer ran from a checkout or was pinned by a
full commit hash), `identity` (whether `git_tree_sha1` is present),
`producer_compat` (the minimum version of [`MINIMUM_PRODUCER_VERSION`](@ref)
checked, empty for an unrecognised producer), `compat_checked` and
`compat_satisfied`, and `schema`. A DeepSpaceTelemetry run descriptor is
recognised by its schema, a MarketTickStreamer session sidecar by its
`[session]` and `[provenance]` tables; any other descriptor by top-level
`producer`, `producer_version` or `package_version` and `git_*` keys. A
descriptor without identity is summarised, never rejected.
"""
function source_summary(descriptor::AbstractDict)
    schema = string(get(descriptor, "schema", ""))
    keys_from = descriptor
    producer = string(get(descriptor, "producer", ""))
    if schema == "deepspacetelemetry-run/1"
        producer = "DeepSpaceTelemetry"
    elseif haskey(descriptor, "session") &&
           get(descriptor, "provenance", nothing) isa AbstractDict
        producer = isempty(producer) ? "MarketTickStreamer" : producer
        keys_from = descriptor["provenance"]
    end
    version = string(something(get(keys_from, "producer_version", nothing),
        get(keys_from, "package_version", "")))
    tree = string(get(keys_from, "git_tree_sha1", ""))
    bound = get(MINIMUM_PRODUCER_VERSION, producer, nothing)
    parsed = tryparse(VersionNumber, version)
    satisfied = bound !== nothing && parsed !== nothing && parsed >= bound
    return Dict{String, Any}("producer" => producer, "producer_version" => version,
        "git_tree_sha1" => tree, "git_dirty" => get(keys_from, "git_dirty", false) === true,
        "git_commit" => commit_or_empty(get(keys_from, "git_commit", "")),
        "identity" => !isempty(tree),
        "producer_compat" => bound === nothing ? "" : string(bound),
        "compat_checked" => bound !== nothing, "compat_satisfied" => satisfied,
        "schema" => schema)
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
