"""
TOML configuration parsing and validation into an immutable [`Settings`](@ref).
Hard errors name the offending key; unknown keys produce warnings.
"""
module Config

using DocStringExtensions: TYPEDFIELDS, TYPEDSIGNATURES
using ..WaitingTimes: TIME_UNITS, QuantizedSeries, threshold, check_digits
using ..Provenance: effective_config

export Settings, load_settings, threshold_list, KNOWN_KEYS

"""
    Settings

Fully parsed and validated pipeline configuration. Constructed by keyword only
through [`load_settings`](@ref).

$(TYPEDFIELDS)
"""
Base.@kwdef struct Settings
    "absolute path of the configuration file"
    config_path::String
    "directory of the configuration file; relative paths resolve against it"
    config_dir::String
    # input
    "absolute path of the input file"
    input_path::String
    "`:csv`, `:dat`, `:arrow` or `:tick`"
    input_format::Symbol
    "dataset descriptor slug, or empty"
    dataset::String
    "value column, by 1-based index or name"
    value_column::Union{Int, String}
    "time column, by index or name; `nothing` for the sample index"
    time_column::Union{Nothing, Int, String}
    "time unit of the series, one of `TIME_UNITS`"
    time_unit::Symbol
    "`Dates` format of textual time stamps, or empty for ISO 8601 / numeric"
    time_format::String
    "unit of numeric time stamps in the file"
    epoch_unit::Symbol
    "field delimiter, or empty for the format's default"
    delimiter::String
    "whether the file has a header row"
    header::Bool
    "`:drop` or `:error`"
    missing_policy::Symbol
    "`:error`, `:first`, `:last` or `:mean`"
    tie_policy::Symbol
    "label of the observed quantity (plots only)"
    quantity_label::String
    "unit label of the observed quantity (plots only)"
    unit_label::String
    # preprocessing
    "ordered preprocessing steps, each a table with an `op` key"
    steps::Vector{Dict{String, Any}}
    # gaps
    "path of a TOML file declaring gap intervals, or empty"
    declared_gaps::String
    "`:none`, `:cadence` or `:threshold`"
    gap_detect::Symbol
    "cadence for `:cadence` detection"
    gap_cadence::Int
    "threshold in time units for `:threshold` detection"
    gap_threshold::Int
    "distribution mode, `:elapsed` or `:exact`"
    mode::Symbol
    # quantization
    "decimal digits of the grid"
    digits::Int
    # thresholds
    "`:linear`, `:log` or `:explicit`"
    threshold_mode::Symbol
    "grid minimum"
    threshold_min::Float64
    "grid maximum"
    threshold_max::Float64
    "linear step"
    threshold_step::Float64
    "points per decade for the logarithmic grid"
    points_per_decade::Int
    "explicit threshold values"
    threshold_values::Vector{Float64}
    # algorithm
    "kernel: `:naive`, `:guarded`, `:segment_tree`, `:fenwick_sweep`, `:streaming`, `:device`"
    search::Symbol
    "device backend: `:none`, `:auto`, `:cuda`, `:oneapi`, `:amdgpu`, `:metal`"
    backend::Symbol
    "indices per task"
    chunk_size::Int
    "thresholds recomputed with the reference kernel per run"
    reference_checks::Int
    "reference kernel: `:naive`, `:guarded` or `:device`"
    reference_kernel::Symbol
    # limits
    "host memory bound in GiB"
    max_ram_gb::Float64
    "device memory bound in GiB"
    max_vram_gb::Float64
    "bound on the element comparisons of one reference check (`scan_work`)"
    max_reference_work::Float64
    # output
    "absolute output root; collections live under it"
    output_root::String
    "`:csv` or `:arrow`"
    output_format::Symbol
    "write dense waiting-time vectors per threshold"
    store_waiting_times::Bool
    "recompute existing partitions after backing them up"
    overwrite::Bool
    # run
    "seed for synthetic generators"
    seed::Int
    "`:debug`, `:info` or `:warn`"
    log_level::Symbol
    "effective configuration as parsed"
    raw::Dict{String, Any}
end

"recognised keys per section, for typo warnings"
const KNOWN_KEYS = Dict(
    "" => ["base_config", "input", "preprocessing", "gaps", "quantization", "thresholds",
        "algorithm", "limits", "output", "run"],
    "input" => ["path", "format", "dataset", "value_column", "time_column", "time_unit",
        "time_format", "epoch_unit", "delimiter", "header", "missing_policy", "tie_policy",
        "quantity_label", "unit_label"],
    "preprocessing" => ["steps"],
    "gaps" => ["declared", "detect", "cadence", "threshold", "mode"],
    "quantization" => ["digits"],
    "thresholds" => ["mode", "min", "max", "step", "points_per_decade", "values"],
    "algorithm" =>
        ["search", "backend", "chunk_size", "reference_checks", "reference_kernel"],
    "limits" => ["max_ram_gb", "max_vram_gb", "max_reference_work"],
    "output" => ["root", "format", "store_waiting_times", "overwrite"],
    "run" => ["seed", "log_level"]
)

"preprocessing operations and their accepted parameter keys"
const STEP_KEYS = Dict(
    "select_range" => ["from", "to"],
    "exclude_intervals" => ["intervals", "splice"],
    "round" => ["digits"],
    "trailing_mean_fluctuations" => ["window", "denominator", "offset", "on_nonpositive"],
    "log_returns" => String[],
    "differences" => String[],
    "centered_moving_average" => ["window"],
    "clip_quantile" => ["q", "splice"],
    "clip_sigma" => ["k", "center", "scale", "splice"],
    "collapse_ties" => ["policy"]
)

"""
Validate the parameters of preprocessing step `k` (types, choices, bounds) so
that a run cannot start from a step it cannot execute.
"""
function validate_step(step::AbstractDict, op::AbstractString, k::Integer)
    where_ = "preprocessing.steps[$k]"
    if op == "select_range"
        haskey(step, "from") && as_float(step["from"], where_, "from")
        haskey(step, "to") && as_float(step["to"], where_, "to")
    elseif op == "exclude_intervals"
        ivs = require(step, where_, "intervals")
        ivs isa AbstractVector &&
        all(iv -> iv isa AbstractVector && length(iv) == 2, ivs) ||
            throw(ArgumentError("[$where_] intervals must be an array of [start, stop] pairs"))
        haskey(step, "splice") && as_bool(step["splice"], where_, "splice")
    elseif op == "round"
        as_int(require(step, where_, "digits"), where_, "digits"; min = 0, max = 15)
    elseif op == "trailing_mean_fluctuations"
        as_int(require(step, where_, "window"), where_, "window"; min = 1)
        denominator = as_symbol(fetch(step, where_, "denominator", "mean"), where_,
            "denominator", (:mean, :scale, :none))
        offset = fetch(step, where_, "offset", "none")
        if offset isa AbstractString
            as_symbol(offset, where_, "offset", (:none, :auto))
        else
            as_float(offset, where_, "offset")
        end
        (offset == "none" || denominator === :mean) ||
            throw(ArgumentError("[$where_] offset applies to denominator = \"mean\" only"))
        as_symbol(fetch(step, where_, "on_nonpositive", "error"), where_, "on_nonpositive",
            (:error, :missing))
    elseif op == "centered_moving_average"
        w = as_int(require(step, where_, "window"), where_, "window"; min = 1)
        isodd(w) || throw(ArgumentError("[$where_] window must be odd, got $w"))
    elseif op == "clip_quantile"
        q = as_float(require(step, where_, "q"), where_, "q"; min = 0.0, max = 1.0)
        q > 0 || throw(ArgumentError("[$where_] q must be positive"))
        haskey(step, "splice") && as_bool(step["splice"], where_, "splice")
    elseif op == "clip_sigma"
        k_ = as_float(fetch(step, where_, "k", 3.0), where_, "k")
        k_ > 0 || throw(ArgumentError("[$where_] k must be positive, got $k_"))
        as_symbol(fetch(step, where_, "center", "mean"), where_, "center", (:mean, :median))
        as_symbol(fetch(step, where_, "scale", "std"), where_, "scale", (:std, :mad))
        haskey(step, "splice") && as_bool(step["splice"], where_, "splice")
    elseif op == "collapse_ties"
        as_symbol(require(step, where_, "policy"), where_, "policy",
            (:error, :first, :last, :mean))
    end
    return nothing
end

function warn_unknown_keys(table::AbstractDict, section::AbstractString)
    known = get(KNOWN_KEYS, section, String[])
    for key in keys(table)
        key in known || @warn "unknown configuration key ignored" section key
    end
    return nothing
end

section(config, name) = get(config, name, Dict{String, Any}())

function fetch(table, section, key, default)
    haskey(table, key) || return default
    return table[key]
end

function require(table, section, key)
    haskey(table, key) ||
        throw(ArgumentError("[$section] $key is required in the configuration"))
    return table[key]
end

function as_symbol(value, section, key, allowed)
    s = Symbol(lowercase(String(value)))
    s in allowed || throw(ArgumentError(
        "[$section] $key = $(repr(value)) is not one of $(join(string.(allowed), ", "))",
    ))
    return s
end

function as_int(value, section, key; min = typemin(Int), max = typemax(Int))
    value isa Integer && !(value isa Bool) ||
        throw(ArgumentError("[$section] $key must be an integer, got $(repr(value))"))
    min <= value <= max ||
        throw(ArgumentError("[$section] $key = $value must lie in $min:$max"))
    return Int(value)
end

function as_float(value, section, key; min = -Inf, max = Inf)
    value isa Real && !(value isa Bool) ||
        throw(ArgumentError("[$section] $key must be a number, got $(repr(value))"))
    isfinite(value) || throw(ArgumentError("[$section] $key must be finite"))
    min <= value <= max ||
        throw(ArgumentError("[$section] $key = $value must lie in [$min, $max]"))
    return Float64(value)
end

function as_bool(value, section, key)
    value isa Bool || throw(ArgumentError("[$section] $key must be true or false"))
    return value
end

function as_string(value, section, key)
    value isa AbstractString ||
        throw(ArgumentError("[$section] $key must be a string, got $(repr(value))"))
    return String(value)
end

function as_column(value, section, key)
    value isa Integer && !(value isa Bool) && return as_int(value, section, key; min = 1)
    value isa AbstractString && return String(value)
    throw(ArgumentError("[$section] $key must be a column index or name"))
end

function resolve_path(path::AbstractString, dir::AbstractString)
    isabspath(path) ? String(path) : normpath(joinpath(dir, path))
end

"""
$(TYPEDSIGNATURES)

Load and validate the configuration at `path` into a [`Settings`](@ref).
Relative paths in the file resolve against its directory; `output_dir`
overrides `[output].root`.
"""
function load_settings(path::AbstractString; output_dir::Union{Nothing, AbstractString} = nothing)
    config_path = abspath(path)
    isfile(config_path) ||
        throw(ArgumentError("configuration file not found: $config_path"))
    config_dir = dirname(config_path)
    raw = effective_config(config_path)
    warn_unknown_keys(raw, "")
    for name in keys(KNOWN_KEYS)
        isempty(name) && continue
        haskey(raw, name) && raw[name] isa AbstractDict &&
            warn_unknown_keys(raw[name], name)
    end

    inp = section(raw, "input")
    input_path = resolve_path(as_string(require(inp, "input", "path"), "input", "path"), config_dir)
    isfile(input_path) || throw(ArgumentError("[input] path does not exist: $input_path"))
    input_format = as_symbol(fetch(inp, "input", "format", "csv"), "input", "format",
        (:csv, :dat, :arrow, :tick))
    time_column_raw = fetch(inp, "input", "time_column", "")
    time_column = time_column_raw == "" ? nothing :
                  as_column(time_column_raw, "input", "time_column")
    time_unit = as_symbol(fetch(inp, "input", "time_unit", "sample"), "input", "time_unit",
        TIME_UNITS)
    time_column === nothing && time_unit !== :sample &&
        throw(ArgumentError(
            "[input] time_unit = :$time_unit requires a time_column",
        ))
    time_column !== nothing && time_unit === :sample &&
        throw(ArgumentError(
            "[input] a time_column requires a time_unit other than \"sample\"",
        ))

    pre = section(raw, "preprocessing")
    steps_raw = fetch(pre, "preprocessing", "steps", Any[])
    steps_raw isa AbstractVector ||
        throw(ArgumentError("[preprocessing] steps must be an array of tables"))
    steps = Vector{Dict{String, Any}}()
    for (k, step) in enumerate(steps_raw)
        step isa AbstractDict ||
            throw(ArgumentError("[preprocessing] steps[$k] must be a table with an op key"))
        op = as_string(require(step, "preprocessing.steps[$k]", "op"), "preprocessing", "op")
        haskey(STEP_KEYS, op) || throw(ArgumentError(
            "[preprocessing] steps[$k].op = $(repr(op)) is not one of $(join(sort(collect(keys(STEP_KEYS))), ", "))",
        ))
        for key in keys(step)
            key == "op" || key in STEP_KEYS[op] ||
                @warn "unknown preprocessing step key ignored" op key
        end
        validate_step(step, op, k)
        push!(steps, Dict{String, Any}(step))
    end

    gaps = section(raw, "gaps")
    declared = as_string(fetch(gaps, "gaps", "declared", ""), "gaps", "declared")
    declared_gaps = isempty(declared) ? "" : resolve_path(declared, config_dir)
    isempty(declared_gaps) || isfile(declared_gaps) ||
        throw(ArgumentError("[gaps] declared file does not exist: $declared_gaps"))
    gap_detect = as_symbol(fetch(gaps, "gaps", "detect", "cadence"), "gaps", "detect",
        (:none, :cadence, :threshold))
    gap_cadence = as_int(fetch(gaps, "gaps", "cadence", 1), "gaps", "cadence"; min = 1)
    gap_threshold = as_int(fetch(gaps, "gaps", "threshold", 0), "gaps", "threshold"; min = 0)
    gap_detect === :threshold && gap_threshold == 0 &&
        throw(ArgumentError("[gaps] detect = \"threshold\" requires threshold > 0"))
    mode = as_symbol(fetch(gaps, "gaps", "mode", "elapsed"), "gaps", "mode", (
        :elapsed, :exact))

    quant = section(raw, "quantization")
    digits = check_digits(as_int(require(quant, "quantization", "digits"),
        "quantization", "digits"; min = 0, max = 15))

    thr = section(raw, "thresholds")
    threshold_mode = as_symbol(
        fetch(thr, "thresholds", "mode", "linear"), "thresholds", "mode",
        (:linear, :log, :explicit))
    threshold_min = as_float(fetch(thr, "thresholds", "min", 0.0), "thresholds", "min"; min = 0.0)
    threshold_max = as_float(fetch(thr, "thresholds", "max", 0.0), "thresholds", "max"; min = 0.0)
    threshold_step = as_float(fetch(thr, "thresholds", "step", 0.0), "thresholds", "step"; min = 0.0)
    points_per_decade = as_int(
        fetch(thr, "thresholds", "points_per_decade", 10), "thresholds",
        "points_per_decade"; min = 1)
    values_raw = fetch(thr, "thresholds", "values", Any[])
    values_raw isa AbstractVector ||
        throw(ArgumentError("[thresholds] values must be an array of numbers"))
    threshold_values = [as_float(v, "thresholds", "values"; min = 0.0) for v in values_raw]
    if threshold_mode === :explicit
        isempty(threshold_values) &&
            throw(ArgumentError("[thresholds] mode = \"explicit\" requires values"))
    else
        threshold_max > threshold_min ||
            throw(ArgumentError("[thresholds] max must exceed min"))
        threshold_mode === :linear && threshold_step <= 0 &&
            throw(ArgumentError("[thresholds] mode = \"linear\" requires step > 0"))
        threshold_mode === :log && threshold_min <= 0 &&
            throw(ArgumentError("[thresholds] mode = \"log\" requires min > 0"))
    end
    for (key, value) in (("min", threshold_min), ("max", threshold_max), (
        "step", threshold_step))
        threshold_mode === :explicit && continue
        threshold_mode === :log && key == "step" && continue
        on_grid(value, digits) ||
            throw(ArgumentError("[thresholds] $key = $value is not on the 10^-$digits grid"))
    end
    for v in threshold_values
        on_grid(v, digits) ||
            throw(ArgumentError("[thresholds] value $v is not on the 10^-$digits grid"))
    end

    alg = section(raw, "algorithm")
    search = as_symbol(
        fetch(alg, "algorithm", "search", "segment_tree"), "algorithm", "search",
        (:naive, :guarded, :segment_tree, :fenwick_sweep, :streaming, :device))
    backend = as_symbol(fetch(alg, "algorithm", "backend", "none"), "algorithm", "backend",
        (:none, :auto, :cuda, :oneapi, :amdgpu, :metal))
    chunk_size = as_int(fetch(alg, "algorithm", "chunk_size", 4096), "algorithm", "chunk_size"; min = 1)
    reference_checks = as_int(fetch(alg, "algorithm", "reference_checks", 2),
        "algorithm", "reference_checks"; min = 0)
    reference_kernel = as_symbol(fetch(alg, "algorithm", "reference_kernel", "naive"),
        "algorithm", "reference_kernel",
        (:naive, :guarded, :device))

    lim = section(raw, "limits")
    max_ram_gb = as_float(fetch(lim, "limits", "max_ram_gb", 16.0), "limits", "max_ram_gb"; min = 0.0)
    max_vram_gb = as_float(fetch(lim, "limits", "max_vram_gb", 8.0), "limits", "max_vram_gb"; min = 0.0)
    max_reference_work = as_float(
        fetch(lim, "limits", "max_reference_work", 1e12), "limits", "max_reference_work"; min = 0.0)

    out = section(raw, "output")
    root = output_dir === nothing ?
           resolve_path(as_string(fetch(out, "output", "root", "data"), "output", "root"), config_dir) :
           abspath(output_dir)
    output_format = as_symbol(fetch(out, "output", "format", "arrow"), "output", "format", (
        :csv, :arrow))
    store_waiting_times = as_bool(
        fetch(out, "output", "store_waiting_times", false), "output", "store_waiting_times")
    overwrite = as_bool(fetch(out, "output", "overwrite", false), "output", "overwrite")

    run = section(raw, "run")
    seed = as_int(fetch(run, "run", "seed", 12345), "run", "seed")
    log_level = as_symbol(fetch(run, "run", "log_level", "info"), "run", "log_level", (
        :debug, :info, :warn))

    return Settings(;
        config_path, config_dir, input_path, input_format,
        dataset = as_string(fetch(inp, "input", "dataset", ""), "input", "dataset"),
        value_column = as_column(require(inp, "input", "value_column"), "input", "value_column"),
        time_column, time_unit,
        time_format = as_string(fetch(inp, "input", "time_format", ""), "input", "time_format"),
        epoch_unit = as_symbol(
            fetch(inp, "input", "epoch_unit", "second"), "input", "epoch_unit",
            TIME_UNITS[2:end]),
        delimiter = as_string(fetch(inp, "input", "delimiter", ""), "input", "delimiter"),
        header = as_bool(fetch(inp, "input", "header", true), "input", "header"),
        missing_policy = as_symbol(fetch(inp, "input", "missing_policy", "drop"), "input",
            "missing_policy", (:drop, :error)),
        tie_policy = as_symbol(
            fetch(inp, "input", "tie_policy", "error"), "input", "tie_policy",
            (:error, :first, :last, :mean)),
        quantity_label = as_string(fetch(inp, "input", "quantity_label", ""), "input", "quantity_label"),
        unit_label = as_string(fetch(inp, "input", "unit_label", ""), "input", "unit_label"),
        steps, declared_gaps, gap_detect, gap_cadence, gap_threshold, mode, digits,
        threshold_mode, threshold_min, threshold_max, threshold_step, points_per_decade,
        threshold_values, search, backend, chunk_size, reference_checks, reference_kernel,
        max_ram_gb, max_vram_gb, max_reference_work,
        output_root = root, output_format, store_waiting_times, overwrite,
        seed, log_level, raw)
end

"whether `value` is a multiple of `10^-digits` to within `1e-6` grid units"
function on_grid(value::Real, digits::Integer)
    scaled = value * 10.0^digits
    return abs(scaled - round(scaled)) <= 1e-6
end

"""
$(TYPEDSIGNATURES)

Sorted distinct thresholds of the configured grid on the grid of `s`.
"""
function threshold_list(settings::Settings, s::QuantizedSeries)
    digits = s.digits
    scale = 10.0^digits
    ds = Int64[]
    if settings.threshold_mode === :explicit
        append!(ds, round(Int64, v * scale) for v in settings.threshold_values)
    elseif settings.threshold_mode === :linear
        d_min = round(Int64, settings.threshold_min * scale)
        d_max = round(Int64, settings.threshold_max * scale)
        d_step = round(Int64, settings.threshold_step * scale)
        d_step >= 1 ||
            throw(ArgumentError("[thresholds] step is below the grid resolution"))
        append!(ds, d_min:d_step:d_max)
    else
        lo = log10(settings.threshold_min)
        hi = log10(settings.threshold_max)
        n = ceil(Int, (hi - lo) * settings.points_per_decade)
        for k in 0:n
            v = 10.0^(lo + k / settings.points_per_decade)
            v > settings.threshold_max && break
            push!(ds, max(1, round(Int64, v * scale)))
        end
        push!(ds, round(Int64, settings.threshold_max * scale))
    end
    unique!(sort!(ds))
    return [threshold(d / scale, s) for d in ds]
end

end # module
