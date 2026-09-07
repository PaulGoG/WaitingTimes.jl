"""
Self-describing file names: a deterministic grammar that carries the series,
model, representation, binning, thresholds and artefact identifier of a file
and parses back to them, so batches of figures and result tables can be
inspected and selected from their names alone.
"""
module Naming

using DocStringExtensions: TYPEDSIGNATURES
using ..Provenance: slugify

export artefact_name, parse_artefact_name

"field separator of the grammar"
const SEPARATOR = "__"

function token(value::AbstractString, field::AbstractString)
    s = slugify(value)
    occursin(SEPARATOR, s) &&
        throw(ArgumentError("$field must not contain $(SEPARATOR): $(repr(value))"))
    return s
end

"""
$(TYPEDSIGNATURES)

File name
`<series>__<model>__<representation>__<binning>__delta=<delta>[__<key>=<value>...]__<id>.<ext>`.
`delta` is a fixed-decimal string or a `start-stop` range string; `extras`
are additional `key => value` pairs; `model` and `binning` may be `"none"`.
"""
function artefact_name(; series::AbstractString, model::AbstractString = "none",
        representation::AbstractString, binning::AbstractString = "none",
        delta::AbstractString, id::AbstractString, ext::AbstractString,
        extras::AbstractVector{<:Pair{<:AbstractString, <:AbstractString}} = Pair{
            String, String}[])
    fields = [token(series, "series"), token(model, "model"),
        token(representation, "representation"), token(binning, "binning"),
        "delta=" * token(delta, "delta")]
    for (key, value) in extras
        key in ("delta", "id") && throw(ArgumentError("extra key $(repr(key)) is reserved"))
        occursin('=', key) &&
            throw(ArgumentError("extra key must not contain '=': $(repr(key))"))
        push!(fields, token(key, "extra key") * "=" * token(value, "extra value"))
    end
    push!(fields, token(id, "id"))
    return join(fields, SEPARATOR) * "." * token(ext, "ext")
end

"""
$(TYPEDSIGNATURES)

Parse a name produced by [`artefact_name`](@ref) into a named tuple with
`series`, `model`, `representation`, `binning`, `delta`, `extras::Dict`,
`id` and `ext`. Throws `ArgumentError` for names outside the grammar.
"""
function parse_artefact_name(name::AbstractString)
    base = basename(name)
    stem, ext = splitext(base)
    isempty(ext) && throw(ArgumentError("name has no extension: $(repr(name))"))
    fields = split(stem, SEPARATOR)
    length(fields) >= 6 ||
        throw(ArgumentError("name has fewer than six fields: $(repr(name))"))
    startswith(fields[5], "delta=") ||
        throw(ArgumentError("fifth field must be delta=...: $(repr(name))"))
    extras = Dict{String, String}()
    for field in fields[6:(end - 1)]
        kv = split(field, "="; limit = 2)
        length(kv) == 2 || throw(ArgumentError("extra field without '=': $(repr(field))"))
        extras[String(kv[1])] = String(kv[2])
    end
    return (series = String(fields[1]), model = String(fields[2]),
        representation = String(fields[3]), binning = String(fields[4]),
        delta = String(fields[5][7:end]), extras = extras, id = String(fields[end]),
        ext = String(ext[2:end]))
end

end # module
