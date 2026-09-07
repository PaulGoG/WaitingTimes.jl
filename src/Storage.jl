"""
Collection storage: per-threshold distribution partitions (CSV or Arrow with
schema metadata), optional dense waiting-time files, the prepared series,
and the regenerated `index.toml`, `summary.csv` and `catalog.csv`.
"""
module Storage

using Arrow: Arrow
using CSV: CSV
using DataFrames: DataFrame, nrow
using Dates: DateTime
using DocStringExtensions: TYPEDSIGNATURES
using ..WaitingTimes: QuantizedSeries, Threshold, WaitingTimeDistribution, counts,
                      cumulative,
                      format_threshold, probabilities, support, survival
using ..Provenance: file_sha256, read_toml, toml_ready, write_toml

export distribution_table, partition_path, write_distribution, read_distribution,
       write_waiting_times, read_waiting_times, write_series_files, read_series_files,
       write_index, read_index, write_summary, write_catalog, load_distributions

function file_extension(format::Symbol)
    format === :arrow ? "arrow" :
    format === :csv ? "csv" :
    throw(ArgumentError("format must be :csv or :arrow, got :$format"))
end

"""
$(TYPEDSIGNATURES)

Table form of a distribution: columns `tau`, `count`, `pmf`, `cdf`, `ccdf`.
"""
function distribution_table(d::WaitingTimeDistribution)
    DataFrame(tau = support(d), count = counts(d),
        pmf = probabilities(d), cdf = cumulative(d), ccdf = survival(d))
end

"""
$(TYPEDSIGNATURES)

Path of the partition of threshold `δ` inside the collection directory.
"""
function partition_path(dir::AbstractString, δ::Threshold, format::Symbol)
    joinpath(dir, "distributions", "delta=" * format_threshold(δ) * "." *
                                   file_extension(format))
end

function write_table(path::AbstractString, table::DataFrame, format::Symbol;
        metadata::AbstractDict = Dict{String, String}())
    mkpath(dirname(path))
    if format === :arrow
        Arrow.write(path, table; metadata = [String(k) => String(v) for (k, v) in metadata])
    else
        CSV.write(path, table)
    end
    return file_sha256(path)
end

function read_table(path::AbstractString)
    endswith(path, ".arrow") ? DataFrame(Arrow.Table(path)) : CSV.read(path, DataFrame)
end

"""
$(TYPEDSIGNATURES)

Write the distribution to `path` (format from `format`, metadata into the Arrow
schema when applicable); returns the file's SHA-256.
"""
function write_distribution(
        path::AbstractString, d::WaitingTimeDistribution, format::Symbol;
        metadata::AbstractDict = Dict{String, String}())
    return write_table(path, distribution_table(d), format; metadata = metadata)
end

"""
$(TYPEDSIGNATURES)

Read a distribution partition as a table.
"""
read_distribution(path::AbstractString) = read_table(path)

"""
$(TYPEDSIGNATURES)

Write the dense waiting-time vector with its classification and bounds
(`tau`, `class`, `lower`, `upper`, one row per index).
"""
function write_waiting_times(
        path::AbstractString, τ::AbstractVector, class::AbstractVector,
        lower::AbstractVector, upper::AbstractVector, format::Symbol;
        metadata::AbstractDict = Dict{String, String}())
    table = DataFrame(tau = τ, class = class, lower = lower, upper = upper)
    return write_table(path, table, format; metadata = metadata)
end

"read a dense waiting-time file"
read_waiting_times(path::AbstractString) = read_table(path)

"""
$(TYPEDSIGNATURES)

Write the prepared series as `series.<ext>` (values, times) and `gaps.csv`
(start, stop) into `dir`; returns the two paths.
"""
function write_series_files(dir::AbstractString, s::QuantizedSeries, format::Symbol)
    mkpath(dir)
    series_path = joinpath(dir, "series." * file_extension(format))
    write_table(series_path, DataFrame(values = s.values, times = s.times), format;
        metadata = Dict("digits" => string(s.digits), "time_unit" => String(s.time_unit)))
    gaps_path = joinpath(dir, "gaps.csv")
    CSV.write(gaps_path, DataFrame(start = first.(s.gaps), stop = last.(s.gaps)))
    return series_path, gaps_path
end

"""
$(TYPEDSIGNATURES)

Read the series written by [`write_series_files`](@ref) back into a
`QuantizedSeries` (with an empty preparation record unless one is given).
"""
function read_series_files(dir::AbstractString, digits::Integer, time_unit::Symbol;
        epoch::Union{Nothing, DateTime} = nothing, record = nothing)
    candidates = filter(f -> startswith(f, "series."), readdir(dir))
    isempty(candidates) && throw(ArgumentError("no series file in $dir"))
    table = read_table(joinpath(dir, first(candidates)))
    gaps_table = read_table(joinpath(dir, "gaps.csv"))
    times = Vector{Int64}(table.times)
    gaps = Tuple{Int64, Int64}[(Int64(a), Int64(b))
                               for (a, b) in zip(gaps_table.start, gaps_table.stop)]
    values = Vector(table.values)
    kwargs = record === nothing ? (;) : (; record = record)
    return QuantizedSeries(values, times, digits; gaps = gaps, time_unit = time_unit,
        epoch = epoch, kwargs...)
end

"""
$(TYPEDSIGNATURES)

Write `index.toml` with the partition entries.
"""
function write_index(dir::AbstractString, entries::AbstractVector)
    return write_toml(joinpath(dir, "index.toml"),
        Dict{String, Any}("partitions" => Any[toml_ready(e) for e in entries]))
end

"""
$(TYPEDSIGNATURES)

Partition entries of `index.toml`, empty when the file is absent.
"""
function read_index(dir::AbstractString)
    path = joinpath(dir, "index.toml")
    isfile(path) || return Dict{String, Any}[]
    return Dict{String, Any}[Dict{String, Any}(e)
                             for e in get(read_toml(path), "partitions", Any[])]
end

const SUMMARY_COLUMNS = ["delta", "mode", "n_candidates", "n_exact", "n_gap_crossing",
    "n_right_censored", "n_waiting", "tau_min", "tau_max", "tau_mean", "tau_median",
    "seconds", "kernel", "session"]

"""
$(TYPEDSIGNATURES)

Write `summary.csv` (one row per partition, sorted by threshold) from the
index entries.
"""
function write_summary(dir::AbstractString, entries::AbstractVector)
    table = DataFrame([Symbol(c) => [get(e, c, missing) for e in entries]
                       for c in SUMMARY_COLUMNS])
    path = joinpath(dir, "summary.csv")
    CSV.write(path, table)
    return path
end

"""
$(TYPEDSIGNATURES)

Write `catalog.csv`: every artefact of the collection with its descriptor
columns, identifier, checksum and session.
"""
function write_catalog(dir::AbstractString, rows::AbstractVector)
    isempty(rows) && return nothing
    keys_ = unique(reduce(vcat, [collect(keys(r)) for r in rows]))
    table = DataFrame([Symbol(k) => [get(r, k, missing) for r in rows] for k in keys_])
    path = joinpath(dir, "catalog.csv")
    CSV.write(path, table)
    return path
end

"""
$(TYPEDSIGNATURES)

Long table of every partition of the collection (`delta` as a fixed-decimal
string, then `tau`, `count`, `pmf`, `cdf`, `ccdf`), optionally restricted to
the given `deltas` strings.
"""
function load_distributions(dir::AbstractString; deltas = nothing)
    entries = read_index(dir)
    frames = DataFrame[]
    for e in entries
        deltas === nothing || e["delta"] in deltas || continue
        table = read_table(joinpath(dir, e["file"]))
        table.delta = fill(String(e["delta"]), nrow(table))
        push!(frames, table[:, [:delta, :tau, :count, :pmf, :cdf, :ccdf]])
    end
    isempty(frames) && return DataFrame(delta = String[], tau = Int64[], count = Int[],
        pmf = Float64[], cdf = Float64[], ccdf = Float64[])
    return reduce(vcat, frames)
end

end # module
