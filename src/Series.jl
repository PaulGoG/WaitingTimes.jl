# Series types: preparation record and the quantised series with explicit gaps.

"""
Recognised time units of a series. `:sample` means the time axis is the
observation index; the others are integer counts of the named unit since the
first observation (or since `epoch` when one is recorded).
"""
const TIME_UNITS = (:sample, :nanosecond, :microsecond, :millisecond, :second,
    :minute, :hour, :day)

"""
    PreparationStep

One recorded preparation operation: its name, parameters and summary
statistics after the step.

$(TYPEDFIELDS)
"""
struct PreparationStep
    "operation name, e.g. `:quantize`"
    op::Symbol
    "parameters the operation was called with"
    parameters::Dict{String, Any}
    "summary statistics recorded after the operation"
    summary::Dict{String, Any}
end

"""
    PreparationRecord

Ordered provenance of a series: the source it came from and every step applied
to it. Steps are appended in place; the record travels with the series.

$(TYPEDFIELDS)
"""
struct PreparationRecord
    "source description, e.g. a file path or `\"synthetic\"`"
    source::String
    "SHA-256 of the source file, empty when unknown"
    source_sha256::String
    "steps in application order"
    steps::Vector{PreparationStep}
end

function PreparationRecord(source::AbstractString = ""; sha256::AbstractString = "")
    PreparationRecord(String(source), String(sha256), PreparationStep[])
end

function record!(record::PreparationRecord, op::Symbol, parameters::Dict{String, Any},
        summary::Dict{String, Any})
    push!(record.steps, PreparationStep(op, parameters, summary))
    return record
end

"""
    QuantizedSeries{Tv<:Integer,Tt<:Integer}

Scalar series on the decimal integer grid with an explicit time axis and an
explicit list of data gaps. Gaps are intervals `[start, stop)` of the time
axis that contain no observation; they are diagnostics for the analyst and
never alter a waiting time (elapsed-time semantics, as in the original
analysis).

$(TYPEDFIELDS)
"""
struct QuantizedSeries{Tv <: Integer, Tt <: Integer}
    "grid values ``q_n = A_n \\cdot 10^{\\mathrm{digits}}``"
    values::Vector{Tv}
    "observation times, strictly increasing"
    times::Vector{Tt}
    "sorted, disjoint gap intervals `[start, stop)` inside the record"
    gaps::Vector{Tuple{Tt, Tt}}
    "decimal digits of the grid"
    digits::Int
    "time unit, one of `TIME_UNITS`"
    time_unit::Symbol
    "absolute origin of the time axis when known"
    epoch::Union{Nothing, DateTime}
    "provenance of the series"
    record::PreparationRecord

    function QuantizedSeries{Tv, Tt}(values::Vector{Tv}, times::Vector{Tt},
            gaps::Vector{Tuple{Tt, Tt}}, digits::Integer, time_unit::Symbol,
            epoch::Union{Nothing, DateTime}, record::PreparationRecord) where {
            Tv <: Integer, Tt <: Integer}
        length(values) == length(times) || throw(DimensionMismatch(
            "values ($(length(values))) and times ($(length(times))) differ in length",
        ))
        isempty(values) && throw(ArgumentError("a series needs at least one observation"))
        time_unit in TIME_UNITS ||
            throw(ArgumentError("time_unit must be one of $(TIME_UNITS), got :$time_unit"))
        for i in 2:length(times)
            times[i] > times[i - 1] || throw(ArgumentError(
                "times must be strictly increasing; violated at index $i " *
                "(t[$(i - 1)] = $(times[i - 1]), t[$i] = $(times[i]))",
            ))
        end
        validate_gaps(gaps, times)
        return new{Tv, Tt}(
            values, times, gaps, check_digits(digits), time_unit, epoch, record)
    end
end

function validate_gaps(gaps::AbstractVector{Tuple{Tt, Tt}}, times::AbstractVector{Tt}) where {Tt}
    t_first, t_last = first(times), last(times)
    for (k, (a, b)) in enumerate(gaps)
        a < b || throw(ArgumentError("gap $k has start $a >= stop $b"))
        (a >= t_first && b <= t_last) ||
            throw(ArgumentError("gap $k [$a, $b) lies outside the record [$t_first, $t_last]"))
        k > 1 && a < gaps[k - 1][2] &&
            throw(ArgumentError("gap $k [$a, $b) overlaps or precedes gap $(k - 1)"))
        i = searchsortedfirst(times, a)
        (i > length(times) || times[i] >= b) || throw(ArgumentError(
            "gap $k [$a, $b) contains the observation at time $(times[i])",
        ))
    end
    return nothing
end

"""
$(TYPEDSIGNATURES)

Series from grid integers and times. `gaps` default to none; `time_unit`
defaults to `:sample`.
"""
function QuantizedSeries(
        values::AbstractVector{Tv}, times::AbstractVector{Tt}, digits::Integer;
        gaps::AbstractVector{Tuple{Tt, Tt}} = Tuple{Tt, Tt}[], time_unit::Symbol = :sample,
        epoch::Union{Nothing, DateTime} = nothing,
        record::PreparationRecord = PreparationRecord()) where {
        Tv <: Integer, Tt <: Integer}
    return QuantizedSeries{Tv, Tt}(Vector{Tv}(values), Vector{Tt}(times),
        Vector{Tuple{Tt, Tt}}(gaps), digits, time_unit, epoch, record)
end

"""
$(TYPEDSIGNATURES)

Series from raw real values that may contain `missing`. Missing entries are
removed from the observation set but keep their time position: with the default
sample-index axis the first observation gets time 1 and every later observation
keeps its original offset, so missing samples count as elapsed time. Runs of
missing samples inside the record become gaps (`cadence = 1`); with explicit
`times` no gaps are detected unless `cadence` is given. Values are quantised
with [`quantize`](@ref) and narrowed to `Int32` when possible (`narrow`).
"""
function QuantizedSeries(x::AbstractVector{<:Union{Missing, Real}}, digits::Integer;
        times::Union{Nothing, AbstractVector{<:Integer}} = nothing,
        cadence::Union{Nothing, Integer} = times === nothing ? 1 : nothing,
        time_unit::Symbol = :sample, epoch::Union{Nothing, DateTime} = nothing,
        record::PreparationRecord = PreparationRecord(), narrow::Bool = true)
    observed = findall(!ismissing, x)
    isempty(observed) && throw(ArgumentError("the series has no non-missing value"))
    if times === nothing
        t = Vector{Int64}(observed)
        t .-= t[1] - 1
    else
        length(times) == length(x) ||
            throw(DimensionMismatch("times ($(length(times))) and values ($(length(x))) differ in length"))
        t = Vector{Int64}(times[observed])
    end
    q64 = quantize(collect(skipmissing(x)), digits)
    q = narrow ? narrow_integer(q64) : q64
    gaps = cadence === nothing ? Tuple{Int64, Int64}[] : detect_gaps(t, cadence)
    record!(record, :quantize,
        Dict{String, Any}("digits" => Int(digits), "cadence" => cadence, "narrow" =>
            narrow),
        Dict{String, Any}("n_rows" => length(x), "n_observed" => length(observed),
            "n_missing" => length(x) - length(observed), "n_gaps" => length(gaps),
            "value_type" => string(eltype(q))))
    return QuantizedSeries(q, t, digits; gaps = gaps, time_unit = time_unit, epoch = epoch,
        record = record)
end

Base.length(s::QuantizedSeries) = length(s.values)

"""
$(TYPEDSIGNATURES)

Elapsed time between the first and the last observation.
"""
duration(s::QuantizedSeries) = last(s.times) - first(s.times)

function Base.show(io::IO, s::QuantizedSeries{Tv, Tt}) where {Tv, Tt}
    print(io, "QuantizedSeries{", Tv, ",", Tt, "}(", length(s), " observations, digits = ",
        s.digits, ", unit = :", s.time_unit, ", span = ", duration(s), ", gaps = ",
        length(s.gaps), ")")
end
