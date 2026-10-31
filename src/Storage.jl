"""
Collection storage: per-threshold distribution partitions (CSV or Arrow with
schema metadata), optional dense waiting-time files, the prepared series,
the regenerated `index.toml`, `summary.csv` and `catalog.csv`, the
collection `README.md`, and the read side: [`Collection`](@ref),
[`load_collection`](@ref), [`distribution`](@ref), [`source_descriptor`](@ref),
[`export_legacy`](@ref).
"""
module Storage

using Arrow: Arrow
using CSV: CSV
using DataFrames: DataFrame, nrow
using Dates: DateTime
using DocStringExtensions: TYPEDFIELDS, TYPEDSIGNATURES
using ..WaitingTimes: WaitingTimes, QuantizedSeries, Threshold, WaitingTimeDistribution,
                      counts,
                      cumulative, format_threshold, gap_entries, parse_threshold,
                      probabilities, record_length, segment_lengths, segment_table, support,
                      survival, nsamples, threshold
using ..Provenance: Provenance, dict_to_record, file_sha256, read_toml, toml_ready,
                    write_toml

export distribution_table, partition_path, write_distribution, read_distribution,
       write_waiting_times, read_waiting_times, write_series_files, read_series_files,
       write_index, read_index, write_summary, write_catalog, write_collection_readme,
       load_distributions, Collection, load_collection, list_collections, distribution,
       thresholds, summary_table, load_series, export_legacy, source_descriptor,
       SOURCE_FILE,
       MANIFEST_FILE,
       censoring_path, write_censoring, write_gap_file, read_gap_file, censoring_histogram

function file_extension(format::Symbol)
    format === :arrow ? "arrow" :
    format === :csv ? "csv" :
    throw(ArgumentError("format must be :csv or :arrow, got :$format"))
end

"""
$(TYPEDSIGNATURES)

Table form of a distribution: columns `tau`, `count`, `pmf`, `cdf`, `ccdf`,
and, when the per-class counts are given (see `class_columns`),
`count_exact` and `count_gap_crossing`.
"""
function distribution_table(d::WaitingTimeDistribution; exact = nothing,
        gap_crossing = nothing)
    table = DataFrame(tau = support(d), count = counts(d),
        pmf = probabilities(d), cdf = cumulative(d), ccdf = survival(d))
    exact === nothing || (table.count_exact = Vector{Int}(exact))
    gap_crossing === nothing || (table.count_gap_crossing = Vector{Int}(gap_crossing))
    return table
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

Write the table of `d` to `path` as `:csv` or `:arrow` (with `metadata` in the
Arrow schema); returns the file's SHA-256.
"""
function write_distribution(
        path::AbstractString, d::WaitingTimeDistribution, format::Symbol;
        metadata::AbstractDict = Dict{String, String}(), exact = nothing,
        gap_crossing = nothing)
    return write_table(path, distribution_table(d; exact, gap_crossing), format;
        metadata = metadata)
end

"""
$(TYPEDSIGNATURES)

Path of the censoring histogram of threshold `δ` inside the collection
directory.
"""
function censoring_path(dir::AbstractString, δ::Threshold, format::Symbol)
    joinpath(dir, "censoring", "delta=" * format_threshold(δ) * "." *
                               file_extension(format))
end

"""
$(TYPEDSIGNATURES)

Write the histogram of the lower bounds of the right-censored indices
(columns `lower`, `count`); returns the file's SHA-256.
"""
function write_censoring(path::AbstractString, lower::AbstractVector,
        count::AbstractVector, format::Symbol;
        metadata::AbstractDict = Dict{String, String}())
    return write_table(path, DataFrame(lower = lower, count = Vector{Int}(count)), format;
        metadata = metadata)
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

"""
$(TYPEDSIGNATURES)

Dense waiting-time file written by `write_waiting_times`, as a table (`tau`,
`class`, `lower`, `upper`).
"""
read_waiting_times(path::AbstractString) = read_table(path)

"text column read back from a table, `missing` (an empty CSV field) as empty"
text_column(col) = String[ismissing(x) ? "" : String(x) for x in col]

"""
$(TYPEDSIGNATURES)

Write a gap list as a CSV table `start, stop, kind, source` at `path`.
"""
function write_gap_file(path::AbstractString, entries::AbstractVector)
    CSV.write(path,
        DataFrame(
            start = Int64[e.start for e in entries], stop = Int64[e.stop for e in entries],
            kind = String[e.kind for e in entries], source = String[e.source
                                                                    for e in entries]))
    return path
end

"""
$(TYPEDSIGNATURES)

Gap list of a table written by [`write_gap_file`](@ref), as named tuples
`(start, stop, kind, source)`; tables of collections written before the kinds
were recorded (columns `start, stop` only) read back with kind `"unknown"`.
"""
function read_gap_file(path::AbstractString)
    table = read_table(path)
    n = nrow(table)
    starts = n == 0 ? Int64[] : Vector{Int64}(table.start)
    stops = n == 0 ? Int64[] : Vector{Int64}(table.stop)
    kinds = hasproperty(table, :kind) && n > 0 ? text_column(table.kind) :
            fill("unknown", n)
    sources = hasproperty(table, :source) && n > 0 ? text_column(table.source) : fill("", n)
    return [(start = a, stop = b, kind = k, source = src)
            for (a, b, k, src) in zip(starts, stops, kinds, sources)]
end

"""
$(TYPEDSIGNATURES)

Write the prepared series into `dir`: `series.<ext>` with the grid values and
times on the collection's time axis and, when given, the row ordinal of every
observation in the prepared input (`row`) and its time on the original clock
(`time_original`), so the collection can be rebuilt on the other axis;
`gaps.csv` (`start, stop, kind, source`); `segments.csv` (`start, stop,
length, kind_before, kind_after`, see [`segment_table`](@ref)); and, when
given, `gaps_original.csv`, the gaps of the original clock. Returns the path
of the series file.
"""
function write_series_files(dir::AbstractString, s::QuantizedSeries, format::Symbol;
        rows = nothing, time_original = nothing, gaps_original = nothing)
    mkpath(dir)
    series_path = joinpath(dir, "series." * file_extension(format))
    table = DataFrame(values = s.values, times = s.times)
    rows === nothing || (table.row = Vector{Int64}(rows))
    time_original === nothing || (table.time_original = Vector{Int64}(time_original))
    write_table(series_path, table, format;
        metadata = Dict("digits" => string(s.digits), "time_unit" => String(s.time_unit)))
    write_gap_file(joinpath(dir, "gaps.csv"), gap_entries(s))
    segments = segment_table(s)
    CSV.write(joinpath(dir, "segments.csv"),
        DataFrame(start = [r.start for r in segments], stop = [r.stop for r in segments],
            length = [r.length for r in segments],
            kind_before = [r.kind_before for r in segments],
            kind_after = [r.kind_after for r in segments]))
    gaps_original === nothing ||
        write_gap_file(joinpath(dir, "gaps_original.csv"), gaps_original)
    return series_path
end

"""
$(TYPEDSIGNATURES)

Read the series written by [`write_series_files`](@ref) back into a
`QuantizedSeries` with the gap kinds and sources of `gaps.csv`, values of
`value_type`, the given `epoch` and `record` (an empty record unless one is
given).
"""
function read_series_files(dir::AbstractString, digits::Integer, time_unit::Symbol;
        epoch::Union{Nothing, DateTime} = nothing, record = nothing,
        value_type::Type{<:Integer} = Int64)
    candidates = filter(f -> occursin(r"^series\.(csv|arrow)$", f), readdir(dir))
    isempty(candidates) && throw(ArgumentError("no series file in $dir"))
    table = read_table(joinpath(dir, first(candidates)))
    gaps = read_gap_file(joinpath(dir, "gaps.csv"))
    kwargs = record === nothing ? (;) : (; record = record)
    return QuantizedSeries(Vector{value_type}(table.values), Vector{Int64}(table.times),
        digits; gaps = Tuple{Int64, Int64}[(e.start, e.stop) for e in gaps],
        gap_kinds = [e.kind for e in gaps], gap_sources = [e.source for e in gaps],
        time_unit = time_unit, epoch = epoch, kwargs...)
end

"""
$(TYPEDSIGNATURES)

Write `index.toml` with the partition entries. The file is written beside its
destination and moved into place, so a reader never sees a partial index.
"""
function write_index(dir::AbstractString, entries::AbstractVector)
    path = joinpath(dir, "index.toml")
    tmp = path * ".tmp"
    write_toml(tmp,
        Dict{String, Any}("partitions" => Any[toml_ready(e) for e in entries]))
    mv(tmp, path; force = true)
    return path
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

Write `summary.csv` from the index entries, one row per entry in the order
given (`generate` passes them sorted by threshold), through a temporary file
moved into place; returns the path.
"""
function write_summary(dir::AbstractString, entries::AbstractVector)
    table = DataFrame([Symbol(c) => [get(e, c, missing) for e in entries]
                       for c in SUMMARY_COLUMNS])
    path = joinpath(dir, "summary.csv")
    tmp = path * ".tmp"
    CSV.write(tmp, table)
    mv(tmp, path; force = true)
    return path
end

"""
$(TYPEDSIGNATURES)

Write `catalog.csv`: every distribution partition of the collection with its
descriptor columns, identifier, checksum and session, through a temporary
file moved into place.
"""
function write_catalog(dir::AbstractString, rows::AbstractVector)
    isempty(rows) && return nothing
    keys_ = unique(reduce(vcat, [collect(keys(r)) for r in rows]))
    table = DataFrame([Symbol(k) => [get(r, k, missing) for r in rows] for k in keys_])
    path = joinpath(dir, "catalog.csv")
    tmp = path * ".tmp"
    CSV.write(tmp, table)
    mv(tmp, path; force = true)
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
    "time axis of the series: `:elapsed` (the clock of the input) or `:index` (row ordinal)"
    time_axis::Symbol
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
                  if String(st["op"]) ∉
                     ("read_series", "quantize", "declare_gaps", "index_axis")]
end

"file name of the verbatim copy of the source descriptor in a collection directory"
const SOURCE_FILE = "source.toml"

"file name of the copy of the resolved manifest of the latest session"
const MANIFEST_FILE = "manifest_snapshot.toml"

"provenance schemas the read side understands"
const READABLE_SCHEMAS = ("waitingtimes-provenance/2", "waitingtimes-provenance/3")

"keys of the `[series]` section a schema-3 collection must carry"
const SERIES_KEYS_3 = ("time_axis", "time_unit", "time_unit_original", "record_length",
    "n_observed", "n_segments", "sampling_step", "gap_kinds", "value_type")

"""
$(TYPEDSIGNATURES)

Open the collection at `dir` (a directory holding `metadata.toml`). The
metadata are validated: the provenance schema must be one this version reads
(`waitingtimes-provenance/2` or `/3`), and a schema-3 collection must state
its time axis (`elapsed` or `index`), time units and record structure.
Collections of schema 2 are read with time axis `:elapsed`.
"""
function load_collection(dir::AbstractString)
    meta_path = joinpath(dir, "metadata.toml")
    isfile(meta_path) || throw(ArgumentError("no metadata.toml in $dir; not a collection"))
    meta = read_toml(meta_path)
    schema = String(get(meta, "schema", ""))
    schema in READABLE_SCHEMAS || throw(ArgumentError(
        "$meta_path has provenance schema $(repr(schema)); this version reads $(join(READABLE_SCHEMAS, ", "))",
    ))
    series = meta["series"]
    if schema == "waitingtimes-provenance/3"
        missing_keys = filter(k -> !haskey(series, k), SERIES_KEYS_3)
        isempty(missing_keys) || throw(ArgumentError(
            "$meta_path: [series] lacks $(join(missing_keys, ", "))",
        ))
    end
    time_axis = Symbol(get(series, "time_axis", "elapsed"))
    time_axis in (:elapsed, :index) || throw(ArgumentError(
        "$meta_path: [series] time_axis = $(repr(String(time_axis))) is not \"elapsed\" or \"index\"",
    ))
    digits = Int(series["digits"])
    entries = read_index(dir)
    sort!(entries; by = e -> parse_threshold(e["delta"], digits).d)
    steps = preprocessing_steps(series)
    return Collection(String(abspath(dir)), String(meta["artefact"]["id"]),
        String(series["slug"]), Symbol(meta["identity"]["mode"]), digits,
        Symbol(series["time_unit"]), time_axis, Int(series["n_observations"]),
        Int(series["n_gaps"]), steps, entries, meta)
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

as_threshold(c::Collection, δ::Threshold) = δ
as_threshold(c::Collection, δ::AbstractString) = parse_threshold(δ, c.digits)
as_threshold(c::Collection, δ::Real) = threshold(δ, c.digits)

"""
$(TYPEDSIGNATURES)

Per-class counts of the partition at `δ` (a `Threshold`, a real value or a
fixed-decimal string): `(support, exact, gap_crossing)`, the exact and
gap-crossing waits at each support value (their sum is the `count` of the
distribution in `:elapsed` mode). `nothing` for a collection written before
the counts were recorded (provenance schema 2).
"""
function WaitingTimes.class_counts(c::Collection, δ)
    entry = partition_entry(c, as_threshold(c, δ))
    table = read_table(joinpath(c.dir, entry["file"]))
    hasproperty(table, :count_exact) || return nothing
    return (support = Vector{Int64}(table.tau), exact = Vector{Int}(table.count_exact),
        gap_crossing = Vector{Int}(table.count_gap_crossing))
end

"""
$(TYPEDSIGNATURES)

Histogram of the lower bounds of the right-censored indices at `δ`:
`(lower, count)`, the elapsed time from each censored index to the last
observation before its first gap (or the end of the record), in increasing
order. `nothing` for a collection written before the histograms were recorded
(provenance schema 2).
"""
function censoring_histogram(c::Collection, δ)
    entry = partition_entry(c, as_threshold(c, δ))
    file = get(entry, "censoring_file", "")
    isempty(file) && return nothing
    table = read_table(joinpath(c.dir, file))
    return (lower = Vector{Int64}(table.lower), count = Vector{Int}(table.count))
end

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

Normalised identity of the source of the collection's input (see
[`source_summary`](@ref WaitingTimes.Provenance.source_summary)): `producer`,
`producer_version`, `git_tree_sha1` (authoritative with `git_dirty`),
`git_dirty`, `git_commit`, `identity`, `producer_compat`, `compat_checked`,
`compat_satisfied` and `schema`, as a named tuple; `nothing` without a source
descriptor. For a collection written before the summary was recorded it is
computed from the stored descriptor.
"""
function Provenance.source_summary(c::Collection)
    source = get(c.metadata, "source", nothing)
    source === nothing && return nothing
    summary = haskey(source, "producer") ? source :
              Provenance.source_summary(source["descriptor"])
    keys_ = (:producer, :producer_version, :git_tree_sha1, :git_dirty, :git_commit,
        :identity, :producer_compat, :compat_checked, :compat_satisfied, :schema)
    return NamedTuple{keys_}(Tuple(summary[String(k)] for k in keys_))
end

"""
$(TYPEDSIGNATURES)

The source descriptor of the collection's input, as configured by
`[input].source_descriptor`: the producer's identity of the data (for a
DeepSpaceTelemetry.jl run its `descriptor.toml`: run identifier, producer
version and code identity, configuration hash, seed, product checksums), or
`nothing` when the collection was generated without one. The file itself is
copied verbatim to `source.toml` in the collection directory, and its SHA-256
is recorded in the `[source]` table of `metadata.toml`. Keys are the
producer's; an absent key means unknown.

```julia
c = load_collection(dir)
source = source_descriptor(c)
# DeepSpaceTelemetry.jl run: git_tree_sha1 with git_dirty = false identifies the producer's code
source === nothing || println(source["run_id"], " ", get(source, "git_tree_sha1", "unknown"))
```
"""
function source_descriptor(c::Collection)
    source = get(c.metadata, "source", nothing)
    source === nothing && return nothing
    return Dict{String, Any}(source["descriptor"])
end

"integer value types a series may be stored with"
const VALUE_TYPES = Dict("Int8" => Int8, "Int16" => Int16, "Int32" => Int32,
    "Int64" => Int64)

"""
$(TYPEDSIGNATURES)

The prepared series of the collection as a `QuantizedSeries`: values of the
stored integer type, times, gaps with their kinds and sources, digits, time
unit, epoch and preparation record as written, so that the series equals the
one the collection was computed from (record values as they pass through
TOML). A schema-2 collection has no stored epoch and its gaps read back with
kind `"unknown"`.
"""
function load_series(c::Collection)
    series = c.metadata["series"]
    epoch = get(series, "epoch", nothing)
    value_type = get(VALUE_TYPES, String(get(series, "value_type", "Int64")), Int64)
    return read_series_files(c.dir, c.digits, c.time_unit;
        epoch = epoch === nothing ? nothing : DateTime(epoch),
        record = dict_to_record(series["record"]), value_type = value_type)
end

"""
$(TYPEDSIGNATURES)

Length of the record of a collection's series in sampling steps (see
[`record_length`](@ref WaitingTimes.record_length)), from its metadata, or
from the series for a schema-2 collection.
"""
function WaitingTimes.record_length(c::Collection)
    haskey(c.metadata["series"], "record_length") &&
        return Int(c.metadata["series"]["record_length"])
    return record_length(load_series(c))
end

"""
$(TYPEDSIGNATURES)

Lengths of the segments of a collection's series (see
[`segment_lengths`](@ref WaitingTimes.segment_lengths)), read from
`segments.csv`, or computed from the series for a schema-2 collection; with
them the erosion weight ``w(k) = \\sum_s (L_s - k)_+`` needs no series.
"""
function WaitingTimes.segment_lengths(c::Collection)
    path = joinpath(c.dir, "segments.csv")
    isfile(path) || return segment_lengths(load_series(c))
    table = read_table(path)
    return nrow(table) == 0 ? Int[] : Vector{Int}(table.length)
end

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
cumulative distribution. Thresholds without an observed wait are skipped.
`slug` defaults to the series slug. Returns the paths written.
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
    c.time_axis === :index &&
        println(io, "  time axis   index (row ordinal of the input; its clock in ",
            get(c.metadata["series"], "time_unit_original", "?"), "s kept in the series file)")
    isempty(c.steps) || println(io, "  steps       ", join(c.steps, " → "))
    println(io, "  mode        :", c.mode)
    source = source_descriptor(c)
    source === nothing || println(io, "  source      ", source_label(source))
    if isempty(c.index)
        println(io, "  thresholds  none")
    else
        println(
            io, "  thresholds  ", length(c.index), " from ", c.index[1]["delta"], " to ",
            c.index[end]["delta"])
    end
    print(io, "  sessions    ", length(get(c.metadata, "sessions", Any[])))
end
"producer, version and run or session of a source descriptor, as far as it states them"
function source_label(descriptor::AbstractDict)
    summary = Provenance.source_summary(descriptor)
    label = isempty(summary["producer"]) ?
            (isempty(summary["schema"]) ? "descriptor without schema" : summary["schema"]) :
            strip(summary["producer"] * " " * summary["producer_version"])
    run = string(get(descriptor, "run_id", ""))
    session = get(descriptor, "session", nothing)
    isempty(run) && session isa AbstractDict && (run = string(get(session, "id", "")))
    identity = summary["identity"] ? "" : ", no code identity"
    return (isempty(run) ? label : label * ", run " * run) * identity
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
        axis = String(get(series, "time_axis", "elapsed"))
        println(io, "- Series: ", series["n_observations"], " observations, ",
            series["n_gaps"], " recorded gaps, values on a grid of ", series["digits"],
            " decimals, time in ", unit, "s",
            axis == "index" ?
            " (index axis: the row ordinal of the input; its clock in " *
            String(get(series, "time_unit_original", "")) * "s is `time_original`)." : ".")
        kinds = get(series, "gap_kinds", Dict{String, Any}())
        isempty(kinds) || println(io, "- Gaps by kind: ",
            join(["$(k) $(kinds[k])" for k in sort!(collect(keys(kinds)))], ", "), ".")
        haskey(series, "n_segments") && println(io, "- Record: ", series["record_length"],
            " grid positions (sampling step ", series["sampling_step"], "), ",
            series["n_segments"], " segments between gaps.")
        isempty(steps) || println(io, "- Preprocessing: ", join(steps, " → "), ".")
        isempty(deltas) ||
            println(io, "- Thresholds: ", length(deltas), " from ", first(deltas), " to ",
                last(deltas), ".")
        haskey(meta, "source") &&
            println(io, "- Source: ", source_label(meta["source"]["descriptor"]),
                "; the descriptor is copied verbatim to `", SOURCE_FILE, "`.")
        println(io, "- Sessions: ", length(get(meta, "sessions", Any[])), ".\n")
        println(io, "## Files\n")
        println(io, "| File | Content |")
        println(io, "|---|---|")
        println(io, "| `distributions/delta=<δ>.", ext,
            "` | one table per threshold: `tau` (waiting time in ", unit,
            "s), `count`, `pmf` (probability mass), `cdf`, `ccdf` (survival), `count_exact` and `count_gap_crossing` (`count` split by class) |")
        println(io, "| `censoring/delta=<δ>.", ext,
            "` | histogram of the lower bounds of the right-censored indices: `lower`, `count` |")
        println(io,
            "| `summary.csv` | one row per threshold: candidates, exact, gap-crossing and right-censored indices, number of waiting times, minimum, maximum, mean and median waiting time, kernel, session |")
        println(io, "| `series.", ext,
            "`, `series.toml` | the prepared series (`values`, `times`, the input row `row` and the original clock `time_original`) and its description and preparation record |")
        println(io,
            "| `gaps.csv`, `segments.csv` | the gaps `[start, stop)` with `kind` and `source`; the runs of observations between them (`start`, `stop`, `length`, `kind_before`, `kind_after`) |")
        axis == "index" && println(io,
            "| `gaps_original.csv` | the gaps of the original clock, with kinds |")
        println(io,
            "| `waiting_times/delta=<δ>.", ext,
            "` | optional: every index's waiting time with class and bounds (`store_waiting_times = true`) |")
        println(io,
            "| `index.toml`, `catalog.csv` | the partitions with their checksums and per-threshold statistics; one catalogue row per partition with its descriptor columns |")
        println(io,
            "| `metadata.toml`, `config.toml`, `sessions/` | provenance: identity, dataset descriptor, source summary, code identity of WaitingTimes (`[producer]`), environment, per-session records, configuration snapshots, hardware |")
        println(io, "| `", MANIFEST_FILE,
            "` | the resolved manifest of the latest session (every session's under `sessions/`) |")
        haskey(meta, "source") && println(io, "| `", SOURCE_FILE,
            "` | the source descriptor of the input, byte for byte as the producer wrote it |")
        println(io, "| `run.log`, `hardware.txt` | log of the runs and platform report |\n")
        println(io, "## Loading\n")
        println(io, "```julia")
        println(io, "using WaitingTimes")
        println(io, "c = load_collection(\"<this directory>\")")
        println(io, "d = distribution(c, \"", isempty(deltas) ? "0" : first(deltas),
            "\")            # a WaitingTimeDistribution")
        println(io, "WaitingTimes.support(d), WaitingTimes.probabilities(d), WaitingTimes.survival(d)")
        println(io, "summary_table(c)                    # the per-threshold statistics")
        println(
            io, "WaitingTimes.class_counts(c, \"", isempty(deltas) ? "0" : first(deltas),
            "\")    # exact and gap-crossing waits per support value")
        println(io, "export_legacy(c, \"out\")            # WTS_<slug>_deltais<δ>.dat files: time pdf cdf")
        println(io, "```\n")
        println(io,
            "Outside Julia, the partitions are plain tables with a header row; `delta` in a file name has exactly ",
            series["digits"], " decimals.")
    end
    return joinpath(dir, "README.md")
end

end # module
