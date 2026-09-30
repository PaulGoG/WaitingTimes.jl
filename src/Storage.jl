"""
Collection storage: per-threshold distribution partitions (CSV or Arrow with
schema metadata), optional dense waiting-time files, the prepared series,
the regenerated `index.toml`, `summary.csv` and `catalog.csv`, the
collection `README.md`, and the read side: [`Collection`](@ref),
[`load_collection`](@ref), [`distribution`](@ref), [`export_legacy`](@ref).
"""
module Storage

using Arrow: Arrow
using CSV: CSV
using DataFrames: DataFrame, nrow
using Dates: DateTime
using DocStringExtensions: TYPEDFIELDS, TYPEDSIGNATURES
using ..WaitingTimes: QuantizedSeries, Threshold, WaitingTimeDistribution, counts,
                      cumulative, format_threshold, parse_threshold, probabilities, support,
                      survival, nsamples, threshold
using ..Provenance: file_sha256, read_toml, toml_ready, write_toml

export distribution_table, partition_path, write_distribution, read_distribution,
       write_waiting_times, read_waiting_times, write_series_files, read_series_files,
       write_index, read_index, write_summary, write_catalog, write_collection_readme,
       load_distributions, Collection, load_collection, list_collections, distribution,
       thresholds, summary_table, load_series, export_legacy

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

# Text columns are plain `String` and unpooled under every supported CSV version,
# so that consumers of the read side see the same column types.
const CSV_READ_TYPES = (; stringtype = String, pool = false)

function read_table(path::AbstractString)
    endswith(path, ".arrow") ? DataFrame(Arrow.Table(path)) :
    CSV.read(path, DataFrame; CSV_READ_TYPES...)
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

# --- the read side -------------------------------------------------------------

"""
    Collection

A collection of waiting-time distributions on disk: its identifiers, the
series it was computed from and the partition index, opened with
[`load_collection`](@ref). Access the distributions with
[`distribution`](@ref), the per-threshold statistics with
[`summary_table`](@ref), the prepared series with [`load_series`](@ref), and
write the tables of the original analysis with [`export_legacy`](@ref).

$(TYPEDFIELDS)
"""
struct Collection
    "collection directory"
    dir::String
    "collection identifier"
    id::String
    "series slug (dataset and preprocessing steps)"
    slug::String
    "distribution mode, `:elapsed` or `:exact`"
    mode::Symbol
    "decimal digits of the grid"
    digits::Int
    "time unit of the waiting times"
    time_unit::Symbol
    "number of observations of the prepared series"
    n_observations::Int
    "number of recorded gaps"
    n_gaps::Int
    "preprocessing steps of the series, in order"
    steps::Vector{String}
    "partition entries of `index.toml`, sorted by threshold"
    index::Vector{Dict{String, Any}}
    "contents of `metadata.toml`"
    metadata::Dict{String, Any}
end

"the transformation steps of a series record, without the ingestion and quantisation entries"
function preprocessing_steps(series::AbstractDict)
    steps = get(get(series, "record", Dict()), "steps", Any[])
    return String[String(st["op"])
                  for st in steps
                  if String(st["op"]) ∉ ("read_series", "quantize", "declare_gaps")]
end

"""
$(TYPEDSIGNATURES)

Open the collection at `dir` (a directory holding `metadata.toml`).
"""
function load_collection(dir::AbstractString)
    meta_path = joinpath(dir, "metadata.toml")
    isfile(meta_path) || throw(ArgumentError("no metadata.toml in $dir; not a collection"))
    meta = read_toml(meta_path)
    series = meta["series"]
    entries = read_index(dir)
    sort!(entries; by = e -> parse(Float64, e["delta"]))
    steps = preprocessing_steps(series)
    return Collection(String(abspath(dir)), String(meta["artefact"]["id"]),
        String(series["slug"]), Symbol(meta["identity"]["mode"]), Int(series["digits"]),
        Symbol(series["time_unit"]), Int(series["n_observations"]), Int(series["n_gaps"]),
        steps, entries, meta)
end

"""
$(TYPEDSIGNATURES)

Thresholds of the collection, sorted.
"""
thresholds(c::Collection) = [parse_threshold(e["delta"], c.digits) for e in c.index]

function partition_entry(c::Collection, δ::Threshold)
    δ.digits == c.digits ||
        throw(ArgumentError("threshold has $(δ.digits) digits, the collection has $(c.digits)"))
    key = format_threshold(δ)
    i = findfirst(e -> e["delta"] == key, c.index)
    i === nothing && throw(ArgumentError("no partition for delta = $key in $(c.id)"))
    return c.index[i]
end

"""
$(TYPEDSIGNATURES)

The distribution of the collection at threshold `δ` (a `Threshold`, a real
value or a fixed-decimal string), read from its partition with the
accounting recorded in the index.
"""
function distribution(c::Collection, δ::Threshold)
    entry = partition_entry(c, δ)
    table = read_table(joinpath(c.dir, entry["file"]))
    support = Vector{Int64}(table.tau)
    counts = Vector{Int}(table.count)
    return WaitingTimeDistribution{Int64}(Threshold{Int64}(δ.d, δ.digits), c.time_unit,
        Symbol(entry["mode"]), support, counts, Vector{Float64}(table.pmf),
        Vector{Float64}(table.cdf), Int(entry["n_candidates"]), Int(entry["n_exact"]),
        Int(entry["n_gap_crossing"]), Int(entry["n_right_censored"]))
end
function distribution(c::Collection, δ::AbstractString)
    distribution(c, parse_threshold(δ, c.digits))
end
distribution(c::Collection, δ::Real) = distribution(c, threshold(δ, c.digits))

"""
$(TYPEDSIGNATURES)

One row per threshold with the counts and statistics of `summary.csv`.
"""
function summary_table(c::Collection)
    path = joinpath(c.dir, "summary.csv")
    isfile(path) &&
        return CSV.read(path, DataFrame; types = Dict(:delta => String), CSV_READ_TYPES...)
    return DataFrame([Symbol(col) => [get(e, col, missing) for e in c.index]
                      for col in SUMMARY_COLUMNS])
end

"""
$(TYPEDSIGNATURES)

The prepared series of the collection as a `QuantizedSeries`.
"""
load_series(c::Collection) = read_series_files(c.dir, c.digits, c.time_unit)

"""
$(TYPEDSIGNATURES)

Every collection under `root` as a table: identifier, series slug, mode,
number of thresholds, smallest and largest threshold, observations, gaps,
sessions and creation time.
"""
function list_collections(root::AbstractString)
    rows = DataFrame(
        id = String[], series = String[], mode = String[], n_thresholds = Int[],
        delta_min = String[], delta_max = String[], n_observations = Int[], n_gaps = Int[],
        sessions = Int[], created = String[], dir = String[])
    isdir(root) || return rows
    for name in sort(readdir(root))
        dir = joinpath(root, name)
        isfile(joinpath(dir, "metadata.toml")) || continue
        c = load_collection(dir)
        push!(rows,
            (c.id, c.slug, String(c.mode), length(c.index),
                isempty(c.index) ? "" : c.index[1]["delta"],
                isempty(c.index) ? "" : c.index[end]["delta"], c.n_observations, c.n_gaps,
                length(get(c.metadata, "sessions", Any[])),
                string(get(c.metadata["artefact"], "created", "")), c.dir))
    end
    return rows
end

"""
$(TYPEDSIGNATURES)

Write the distributions of the collection in the format of the original
analysis: one space-delimited file `WTS_<slug>_deltais<δ>.dat` per threshold
under `out_dir`, with the header `time pdf cdf` and CRLF line ends, where
`time` is the waiting time, `pdf` its probability mass and `cdf` the
cumulative distribution. `slug` defaults to the series slug. Returns the
paths written.
"""
function export_legacy(c::Collection, out_dir::AbstractString; slug::AbstractString = c.slug)
    mkpath(out_dir)
    paths = String[]
    for δ in thresholds(c)
        d = distribution(c, δ)
        nsamples(d) == 0 && continue
        path = joinpath(out_dir, "WTS_" * slug * "_deltais" * format_threshold(δ) * ".dat")
        K = nsamples(d)
        cumulative_counts = cumsum(counts(d))
        open(path, "w") do io
            print(io, "time pdf cdf\r\n")
            for (k, n, m) in zip(support(d), counts(d), cumulative_counts)
                print(io, k, ' ', n / K, ' ', m / K, "\r\n")
            end
        end
        push!(paths, path)
    end
    return paths
end

function Base.show(io::IO, ::MIME"text/plain", c::Collection)
    println(io, "Collection ", c.id)
    println(io, "  directory   ", c.dir)
    println(io, "  series      ", c.slug, " (", c.n_observations, " observations, ",
        c.n_gaps, " gaps, digits = ", c.digits, ", unit = :", c.time_unit, ")")
    isempty(c.steps) || println(io, "  steps       ", join(c.steps, " → "))
    println(io, "  mode        :", c.mode)
    if isempty(c.index)
        println(io, "  thresholds  none")
    else
        println(
            io, "  thresholds  ", length(c.index), " from ", c.index[1]["delta"], " to ",
            c.index[end]["delta"])
    end
    print(io, "  sessions    ", length(get(c.metadata, "sessions", Any[])))
end
function Base.show(io::IO, c::Collection)
    print(io, "Collection(", c.id, ", ", length(c.index),
        " thresholds)")
end

"""
$(TYPEDSIGNATURES)

Write `README.md` into the collection directory: what the collection is,
the files and their columns, and how to load them; regenerated after every
session.
"""
function write_collection_readme(dir::AbstractString, meta::AbstractDict,
        entries::AbstractVector, format::Symbol)
    series = meta["series"]
    steps = preprocessing_steps(series)
    ext = file_extension(format)
    deltas = [e["delta"] for e in entries]
    unit = String(series["time_unit"])
    open(joinpath(dir, "README.md"), "w") do io
        println(io, "# ", meta["artefact"]["id"], "\n")
        println(io, "Waiting-time distributions of the series `", series["slug"],
            "` (dataset `", meta["dataset"]["slug"], "`), one per threshold δ, in `",
            meta["identity"]["mode"], "` mode. Computed by WaitingTimes.jl.\n")
        println(io, "- Series: ", series["n_observations"], " observations, ",
            series["n_gaps"], " recorded gaps, values on a grid of ", series["digits"],
            " decimals, time in ", unit, "s.")
        isempty(steps) || println(io, "- Preprocessing: ", join(steps, " → "), ".")
        isempty(deltas) ||
            println(io, "- Thresholds: ", length(deltas), " from ", first(deltas), " to ",
                last(deltas), ".")
        println(io, "- Sessions: ", length(get(meta, "sessions", Any[])), ".\n")
        println(io, "## Files\n")
        println(io, "| File | Content |")
        println(io, "|---|---|")
        println(io, "| `distributions/delta=<δ>.", ext,
            "` | one table per threshold: `tau` (waiting time in ", unit,
            "s), `count`, `pmf` (probability mass), `cdf`, `ccdf` (survival) |")
        println(io,
            "| `summary.csv` | one row per threshold: candidates, exact, gap-crossing and right-censored indices, number of waiting times, minimum, maximum, mean and median waiting time, kernel, session |")
        println(io, "| `series.", ext,
            "`, `gaps.csv`, `series.toml` | the prepared series (grid values and times), its gaps `[start, stop)`, its preparation record |")
        println(io,
            "| `waiting_times/delta=<δ>.", ext,
            "` | optional: every index's waiting time with class and bounds (`store_waiting_times = true`) |")
        println(io,
            "| `index.toml`, `catalog.csv` | machine index of the partitions with checksums |")
        println(io,
            "| `metadata.toml`, `config.toml`, `sessions/` | provenance: identity, dataset descriptor, per-session records, configuration snapshots, hardware |")
        println(io, "| `run.log`, `hardware.txt` | log of the runs and platform report |\n")
        println(io, "## Loading\n")
        println(io, "```julia")
        println(io, "using WaitingTimes")
        println(io, "c = load_collection(\"<this directory>\")")
        println(io, "d = distribution(c, \"", isempty(deltas) ? "0" : first(deltas),
            "\")            # a WaitingTimeDistribution")
        println(io, "WaitingTimes.support(d), WaitingTimes.probabilities(d), WaitingTimes.survival(d)")
        println(io, "summary_table(c)                    # the per-threshold statistics")
        println(io, "export_legacy(c, \"out\")            # WTS_<slug>_deltais<δ>.dat files: time pdf cdf")
        println(io, "```\n")
        println(io,
            "Any language: the partitions are plain tables with a header row; `delta` in a file name has exactly ",
            series["digits"], " decimals.")
    end
    return joinpath(dir, "README.md")
end

end # module
