"""
Raw-data preparation: ingestion of CSV, DAT, Arrow and tick files into a
[`RawSeries`](@ref), diagnostics, and recorded transformations that end in a
`QuantizedSeries`. Every transformation is pure and appends a step to the
series' preparation record.
"""
module Preprocessing

using Arrow: Arrow
using CSV: CSV
using DataFrames: DataFrame
using Dates: DateTime, DateFormat, Dates, unix2datetime
using DocStringExtensions: TYPEDFIELDS, TYPEDSIGNATURES
using Statistics: mean, median, quantile
using UnicodePlots: UnicodePlots
using ..WaitingTimes: PreparationRecord, QuantizedSeries, TIME_UNITS, declare_gaps,
                      record!
using ..Provenance: file_sha256, read_toml

export RawSeries, read_series, select_range, exclude_intervals, trailing_mean_fluctuations,
       log_returns, differences, centered_moving_average, clip_quantile, collapse_ties,
       sampling_summary, value_summary, terminal_overview, quantized_series, apply_steps,
       read_gap_intervals

"""
    RawSeries

Real-valued series before quantisation: values (with `missing`), optional
integer times, time unit and epoch, and the preparation record.

$(TYPEDFIELDS)
"""
struct RawSeries
    "observed values, `missing` where absent"
    values::Vector{Union{Missing, Float64}}
    "integer times in `time_unit`, or `nothing` for the sample index"
    times::Union{Nothing, Vector{Int64}}
    "time unit"
    time_unit::Symbol
    "origin of absolute times, when known"
    epoch::Union{Nothing, DateTime}
    "preparation record"
    record::PreparationRecord
    function RawSeries(values, times, time_unit, epoch, record)
        isempty(values) && throw(ArgumentError("a series needs at least one row"))
        times === nothing || length(times) == length(values) ||
            throw(DimensionMismatch("times ($(length(times))) and values ($(length(values))) differ"))
        time_unit in TIME_UNITS ||
            throw(ArgumentError("time_unit must be one of $(TIME_UNITS), got :$time_unit"))
        return new(values, times, time_unit, epoch, record)
    end
end

Base.length(rs::RawSeries) = length(rs.values)

"nanoseconds per unit"
const UNIT_NANOSECONDS = Dict(:nanosecond => 1, :microsecond => 10^3, :millisecond => 10^6,
    :second => 10^9, :minute => 60 * 10^9, :hour => 3600 * 10^9, :day => 86400 * 10^9)

# --- ingestion ---------------------------------------------------------------

"""
$(TYPEDSIGNATURES)

Read a series from `path`. `format` is `:csv`, `:dat` (space-delimited with a
header), `:arrow`, `:tick` (MarketTickStreamer compacted files: `time_ns` and
`price`) or `:auto` (from the extension). Columns are selected by 1-based index
or name. Numeric time stamps are integers in `epoch_unit`; textual ones are
parsed with `time_format` or as ISO 8601; both are converted to `time_unit`
since the UNIX epoch and must be exact multiples of the unit. Values that are
absent or unparsable become `missing` under `missing_policy = :drop` or raise
under `:error`. Equal time stamps are resolved by `tie_policy` (`:error`,
`:first`, `:last`, `:mean`).
"""
function read_series(path::AbstractString; format::Symbol = :auto,
        value_column::Union{Integer, AbstractString},
        time_column::Union{Nothing, Integer, AbstractString} = nothing,
        time_unit::Symbol = :sample, time_format::AbstractString = "",
        epoch_unit::Symbol = :second, delimiter::AbstractString = "", header::Bool = true,
        missing_policy::Symbol = :drop, tie_policy::Symbol = :error)
    isfile(path) || throw(ArgumentError("input file not found: $path"))
    format === :auto && (format = infer_format(path))
    if format === :tick
        time_column === nothing && (time_column = "time_ns")
        value_column == "" && (value_column = "price")
        epoch_unit = :nanosecond
        time_unit === :sample && (time_unit = :nanosecond)
    end
    table = read_table(path, format; delimiter, header)
    values = parse_values(column(table, value_column, "value_column"), missing_policy)
    record = PreparationRecord(path; sha256 = file_sha256(path))
    times = nothing
    epoch = nothing
    if time_column !== nothing
        time_unit === :sample &&
            throw(ArgumentError("a time column requires a time unit other than :sample"))
        times, epoch = parse_times(column(table, time_column, "time_column"), time_unit,
            epoch_unit, time_format)
    end
    record!(record, :read_series,
        Dict{String, Any}("format" => String(format), "value_column" => value_column,
            "time_column" => time_column, "time_unit" => String(time_unit),
            "epoch_unit" => String(epoch_unit), "missing_policy" => String(missing_policy),
            "tie_policy" => String(tie_policy)),
        Dict{String, Any}("n_rows" => length(values), "n_missing" =>
            count(ismissing, values)))
    rs = RawSeries(values, times, time_unit, epoch, record)
    times === nothing && return rs
    return collapse_ties(rs, tie_policy)
end

function infer_format(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    ext == ".csv" && return :csv
    ext == ".dat" && return :dat
    ext in (".arrow", ".feather") && return :arrow
    throw(ArgumentError("cannot infer the format of $path; pass format explicitly"))
end

function read_table(path, format; delimiter, header)
    if format === :arrow
        return DataFrame(Arrow.Table(path))
    elseif format === :dat
        return CSV.read(
            path, DataFrame; delim = isempty(delimiter) ? ' ' : only(delimiter),
            ignorerepeated = true, header = header, silencewarnings = true, stringtype = String)
    else
        kwargs = isempty(delimiter) ? (;) : (; delim = only(delimiter))
        return CSV.read(path, DataFrame; header = header, ignoreemptyrows = false,
            silencewarnings = true, stringtype = String, kwargs...)
    end
end

function column(table::DataFrame, selector, what)
    if selector isa Integer
        1 <= selector <= length(names(table)) || throw(ArgumentError(
            "$what = $selector is outside 1:$(length(names(table)))",
        ))
        return table[!, selector]
    end
    selector in names(table) ||
        throw(ArgumentError("$what = $(repr(selector)) is not a column; columns are $(names(table))"))
    return table[!, selector]
end

function parse_values(col, missing_policy::Symbol)
    n = length(col)
    values = Vector{Union{Missing, Float64}}(undef, n)
    for (i, v) in enumerate(col)
        parsed = to_float(v)
        if parsed === missing
            missing_policy === :error &&
                throw(ArgumentError("missing or unparsable value at row $i: $(repr(v))"))
        end
        values[i] = parsed
    end
    return values
end

to_float(::Missing) = missing
to_float(v::Real) = isfinite(v) ? Float64(v) : missing
function to_float(v::AbstractString)
    s = strip(v)
    isempty(s) && return missing
    parsed = tryparse(Float64, s)
    return parsed === nothing || !isfinite(parsed) ? missing : parsed
end
to_float(v) = missing

function parse_times(col, time_unit::Symbol, epoch_unit::Symbol, time_format::AbstractString)
    n = length(col)
    times = Vector{Int64}(undef, n)
    unit_ns = UNIT_NANOSECONDS[time_unit]
    fmt = isempty(time_format) ? nothing : DateFormat(time_format)
    for (i, v) in enumerate(col)
        ns = time_to_ns(v, epoch_unit, fmt, i)
        rem(ns, unit_ns) == 0 || throw(ArgumentError(
            "time stamp at row $i ($(repr(v))) is not a whole number of $(time_unit)s",
        ))
        times[i] = div(ns, unit_ns)
    end
    return times, unix2datetime(0)
end

function time_to_ns(v::Real, epoch_unit, _, i)
    v isa Integer || isinteger(v) ||
        throw(ArgumentError("numeric time stamp at row $i is not an integer: $v"))
    return Int64(v) * UNIT_NANOSECONDS[epoch_unit]
end
time_to_ns(v::DateTime, _, _, _) = Dates.value(v - unix2datetime(0)) * 10^6
function time_to_ns(v::AbstractString, epoch_unit, fmt, i)
    s = strip(v)
    numeric = tryparse(Int64, s)
    numeric === nothing || return time_to_ns(numeric, epoch_unit, fmt, i)
    dt = fmt === nothing ? tryparse(DateTime, s) : tryparse(DateTime, s, fmt)
    dt === nothing && throw(ArgumentError("cannot parse time stamp at row $i: $(repr(v))"))
    return time_to_ns(dt, epoch_unit, fmt, i)
end
function time_to_ns(v, _, _, i)
    throw(ArgumentError("unsupported time stamp at row $i: $(repr(v))"))
end

# --- transformations ---------------------------------------------------------

function with_values(rs::RawSeries, values, op::Symbol, parameters, summary)
    record!(rs.record, op, Dict{String, Any}(parameters), Dict{String, Any}(summary))
    return RawSeries(values, rs.times, rs.time_unit, rs.epoch, rs.record)
end

"""
$(TYPEDSIGNATURES)

Resolve equal time stamps: `:error` rejects them, `:first`/`:last` keep one
observation, `:mean` averages the observed values. Rows are merged, so the
series length may shrink.
"""
function collapse_ties(rs::RawSeries, policy::Symbol)
    rs.times === nothing && return rs
    policy in (:error, :first, :last, :mean) ||
        throw(ArgumentError("tie policy must be :error, :first, :last or :mean, got :$policy"))
    times = rs.times
    for i in 2:length(times)
        times[i] >= times[i - 1] ||
            throw(ArgumentError("time stamps must be non-decreasing; row $i precedes row $(i - 1)"))
    end
    n_ties = count(i -> times[i] == times[i - 1], 2:length(times))
    n_ties == 0 && return rs
    policy === :error && throw(ArgumentError(
        "$n_ties equal time stamps; set tie_policy to :first, :last or :mean",
    ))
    new_values = Union{Missing, Float64}[]
    new_times = Int64[]
    i = 1
    while i <= length(times)
        j = i
        while j < length(times) && times[j + 1] == times[i]
            j += 1
        end
        group = collect(skipmissing(view(rs.values, i:j)))
        value = isempty(group) ? missing :
                policy === :first ? first(group) :
                policy === :last ? last(group) : mean(group)
        push!(new_values, value)
        push!(new_times, times[i])
        i = j + 1
    end
    record!(rs.record, :collapse_ties, Dict{String, Any}("policy" => String(policy)),
        Dict{String, Any}("n_ties" => n_ties, "n_rows" => length(new_values)))
    return RawSeries(new_values, new_times, rs.time_unit, rs.epoch, rs.record)
end

"""
$(TYPEDSIGNATURES)

Keep the rows with time (or index, for sample-indexed series) in `[from, to]`.
"""
function select_range(rs::RawSeries; from::Real = -Inf, to::Real = Inf)
    axis = rs.times === nothing ? (1:length(rs)) : rs.times
    keep = [from <= a <= to for a in axis]
    any(keep) || throw(ArgumentError("select_range [$from, $to] keeps no row"))
    values = rs.values[keep]
    times = rs.times === nothing ? nothing : rs.times[keep]
    record!(rs.record, :select_range, Dict{String, Any}("from" => from, "to" => to),
        Dict{String, Any}("n_rows" => length(values)))
    return RawSeries(values, times, rs.time_unit, rs.epoch, rs.record)
end

"""
$(TYPEDSIGNATURES)

Surgical removal of blocks: rows whose time (or index) lies in any `[a, b)`
interval are removed. With `splice = true` the time axis closes over each cut
(later times shift back by the cut length, so no elapsed time is counted
across it); with `splice = false` the rows are set to `missing` and the cut
remains a gap.
"""
function exclude_intervals(rs::RawSeries, intervals::AbstractVector; splice::Bool = true)
    ivs = [(Int64(a), Int64(b)) for (a, b) in intervals]
    for (a, b) in ivs
        a < b || throw(ArgumentError("interval [$a, $b) is empty"))
    end
    sort!(ivs; by = first)
    n = length(rs)
    axis = rs.times === nothing ? collect(Int64, 1:n) : rs.times
    inside = falses(n)
    for (a, b) in ivs
        for i in searchsortedfirst(axis, a):(searchsortedfirst(axis, b) - 1)
            inside[i] = true
        end
    end
    removed = count(inside)
    if splice
        keep = .!inside
        any(keep) || throw(ArgumentError("exclude_intervals removes every row"))
        values = rs.values[keep]
        if rs.times === nothing
            times = nothing
        else
            shift = zeros(Int64, n)
            offset = zero(Int64)
            k = 1
            for i in 1:n
                while k <= length(ivs) && ivs[k][2] <= axis[i]
                    offset += ivs[k][2] - ivs[k][1]
                    k += 1
                end
                shift[i] = offset
            end
            times = (axis .- shift)[keep]
            for i in 2:length(times)
                times[i] > times[i - 1] || throw(ArgumentError(
                    "splicing produced non-increasing times at row $i; cut intervals overlap observations",
                ))
            end
        end
    else
        values = copy(rs.values)
        values[inside] .= missing
        times = rs.times
    end
    record!(rs.record, :exclude_intervals,
        Dict{String, Any}("intervals" => [[a, b] for (a, b) in ivs], "splice" => splice),
        Dict{String, Any}("n_removed" => removed, "n_rows" => length(values)))
    return RawSeries(values, times, rs.time_unit, rs.epoch, rs.record)
end

"observed positions and values"
function observed(rs::RawSeries)
    idx = findall(!ismissing, rs.values)
    return idx, Float64[rs.values[i] for i in idx]
end

"""
$(TYPEDSIGNATURES)

Fluctuation of every observation from the mean of the previous `window`
observations, in percent; the first observation is set to zero. Baselines
must be positive (use `differences` or `log_returns` otherwise).
"""
function trailing_mean_fluctuations(rs::RawSeries; window::Integer)
    window >= 1 || throw(ArgumentError("window must be at least 1, got $window"))
    idx, x = observed(rs)
    isempty(x) && throw(ArgumentError("the series has no observed value"))
    y = similar(x)
    y[1] = 0.0
    running = x[1]
    for k in 2:length(x)
        first_in = max(1, k - window)
        count_in = k - first_in
        baseline = running / count_in
        baseline > 0 || throw(ArgumentError(
            "non-positive baseline $baseline before observation $k; percentage fluctuations are undefined",
        ))
        y[k] = (x[k] - baseline) * 100 / baseline
        running += x[k]
        k - window >= 1 && (running -= x[k - window])
    end
    values = Vector{Union{Missing, Float64}}(missing, length(rs))
    values[idx] .= y
    return with_values(rs, values, :trailing_mean_fluctuations,
        Dict("window" => Int(window)), Dict("min" => minimum(y), "max" => maximum(y)))
end

"""
$(TYPEDSIGNATURES)

Logarithmic returns in percent, `100 log(x_k / x_{k-1})` between consecutive
observations; the first observation becomes `missing`. Values must be positive.
"""
function log_returns(rs::RawSeries)
    idx, x = observed(rs)
    all(>(0), x) || throw(ArgumentError("log returns need positive values"))
    values = Vector{Union{Missing, Float64}}(missing, length(rs))
    for k in 2:length(x)
        values[idx[k]] = 100 * log(x[k] / x[k - 1])
    end
    return with_values(rs, values, :log_returns, Dict(), Dict("n_rows" => length(values)))
end

"""
$(TYPEDSIGNATURES)

Differences between consecutive observations; the first becomes `missing`.
"""
function differences(rs::RawSeries)
    idx, x = observed(rs)
    values = Vector{Union{Missing, Float64}}(missing, length(rs))
    for k in 2:length(x)
        values[idx[k]] = x[k] - x[k - 1]
    end
    return with_values(rs, values, :differences, Dict(), Dict("n_rows" => length(values)))
end

"""
$(TYPEDSIGNATURES)

Detrend by subtracting the centred moving average of the observed values over
an odd `window` (truncated at the ends).
"""
function centered_moving_average(rs::RawSeries; window::Integer)
    window >= 1 && isodd(window) ||
        throw(ArgumentError("window must be odd and positive, got $window"))
    idx, x = observed(rs)
    half = window ÷ 2
    n = length(x)
    prefix = cumsum(x)
    values = Vector{Union{Missing, Float64}}(missing, length(rs))
    for k in 1:n
        lo = max(1, k - half)
        hi = min(n, k + half)
        total = prefix[hi] - (lo > 1 ? prefix[lo - 1] : 0.0)
        values[idx[k]] = x[k] - total / (hi - lo + 1)
    end
    return with_values(rs, values, :centered_moving_average, Dict("window" => Int(window)),
        Dict("n_rows" => length(values)))
end

"""
$(TYPEDSIGNATURES)

Set observations whose magnitude exceeds the `q` quantile of `|x|` to
`missing` (their time positions remain).
"""
function clip_quantile(rs::RawSeries; q::Real)
    0 < q <= 1 || throw(ArgumentError("q must lie in (0, 1], got $q"))
    idx, x = observed(rs)
    cut = quantile(abs.(x), q)
    values = copy(rs.values)
    removed = 0
    for (k, i) in enumerate(idx)
        if abs(x[k]) > cut
            values[i] = missing
            removed += 1
        end
    end
    return with_values(rs, values, :clip_quantile, Dict("q" => Float64(q)),
        Dict("cut" => cut, "n_removed" => removed))
end

"""
$(TYPEDSIGNATURES)

Apply preprocessing `steps` (tables with an `op` key) in order.
"""
function apply_steps(rs::RawSeries, steps::AbstractVector)
    for step in steps
        op = String(step["op"])
        if op == "select_range"
            rs = select_range(rs; from = get(step, "from", -Inf), to = get(step, "to", Inf))
        elseif op == "exclude_intervals"
            rs = exclude_intervals(rs, [Tuple(iv) for iv in step["intervals"]];
                splice = get(step, "splice", true))
        elseif op == "trailing_mean_fluctuations"
            rs = trailing_mean_fluctuations(rs; window = step["window"])
        elseif op == "log_returns"
            rs = log_returns(rs)
        elseif op == "differences"
            rs = differences(rs)
        elseif op == "centered_moving_average"
            rs = centered_moving_average(rs; window = step["window"])
        elseif op == "clip_quantile"
            rs = clip_quantile(rs; q = step["q"])
        elseif op == "collapse_ties"
            rs = collapse_ties(rs, Symbol(step["policy"]))
        else
            throw(ArgumentError("unknown preprocessing op $(repr(op))"))
        end
    end
    return rs
end

"""
$(TYPEDSIGNATURES)

Gap intervals `[start, stop)` from a TOML file with `intervals = [[a, b], ...]`.
"""
function read_gap_intervals(path::AbstractString)
    table = read_toml(path)
    haskey(table, "intervals") || throw(ArgumentError("$path has no intervals key"))
    return [(Int64(iv[1]), Int64(iv[2])) for iv in table["intervals"]]
end

"""
$(TYPEDSIGNATURES)

Quantise a prepared series: values to the `digits` grid, missing rows kept as
elapsed time, gaps detected by `detect` (`:none`, `:cadence` with `cadence`,
`:threshold` with `threshold`) and merged with `declared` intervals.
"""
function quantized_series(rs::RawSeries, digits::Integer; detect::Symbol = :cadence,
        cadence::Integer = 1, threshold::Integer = 0,
        declared::AbstractVector = Tuple{Int64, Int64}[], narrow::Bool = true)
    detect in (:none, :cadence, :threshold) ||
        throw(ArgumentError("detect must be :none, :cadence or :threshold, got :$detect"))
    cadence_used = detect === :none ? nothing :
                   detect === :cadence ? cadence : threshold
    cadence_used === nothing || cadence_used >= 1 ||
        throw(ArgumentError("gap detection needs a positive cadence or threshold"))
    s = QuantizedSeries(rs.values, digits; times = rs.times, cadence = cadence_used,
        time_unit = rs.time_unit, epoch = rs.epoch, record = rs.record, narrow = narrow)
    isempty(declared) && return s
    return declare_gaps(s, declared)
end

# --- diagnostics -------------------------------------------------------------

"""
$(TYPEDSIGNATURES)

Sampling diagnostics: rows, observed and missing counts, and for the observed
time axis the minimum, median and maximum spacing and the number of spacings
above `gap_factor` times the median.
"""
function sampling_summary(rs::RawSeries; gap_factor::Real = 2)
    idx, _ = observed(rs)
    axis = rs.times === nothing ? collect(Int64, 1:length(rs)) : rs.times
    spacing = length(idx) >= 2 ? diff(axis[idx]) : Int64[]
    med = isempty(spacing) ? 0.0 : median(spacing)
    return (n_rows = length(rs), n_observed = length(idx),
        n_missing = length(rs) - length(idx),
        spacing_min = isempty(spacing) ? 0 : minimum(spacing),
        spacing_median = med,
        spacing_max = isempty(spacing) ? 0 : maximum(spacing),
        n_wide_spacings = count(>(gap_factor * med), spacing),
        time_unit = rs.time_unit)
end

"""
$(TYPEDSIGNATURES)

Value diagnostics of the observed values: count, minimum, quartiles, median,
maximum, mean.
"""
function value_summary(rs::RawSeries)
    _, x = observed(rs)
    isempty(x) &&
        return (n = 0, min = NaN, q25 = NaN, median = NaN, q75 = NaN, max = NaN, mean = NaN)
    return (n = length(x), min = minimum(x), q25 = quantile(x, 0.25), median = median(x),
        q75 = quantile(x, 0.75), max = maximum(x), mean = mean(x))
end

"""
$(TYPEDSIGNATURES)

Print an in-terminal overview: a decimated line plot of the observed values
against time and a histogram of the values.
"""
function terminal_overview(io::IO, rs::RawSeries; width::Integer = 80, points::Integer = 2000)
    idx, x = observed(rs)
    isempty(x) && return println(io, "no observed values")
    axis = rs.times === nothing ? collect(Int64, 1:length(rs)) : rs.times
    stride = max(1, length(idx) ÷ points)
    sel = 1:stride:length(idx)
    println(io,
        UnicodePlots.lineplot(Float64.(axis[idx[sel]]), x[sel]; width = width,
            xlabel = "time [$(rs.time_unit)]", ylabel = "value", canvas = UnicodePlots.BrailleCanvas))
    println(io, UnicodePlots.histogram(x; width = width, nbins = 40))
    return nothing
end
terminal_overview(rs::RawSeries; kwargs...) = terminal_overview(stdout, rs; kwargs...)

end # module
