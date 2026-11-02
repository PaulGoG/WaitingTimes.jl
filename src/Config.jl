"""
TOML configuration parsing and validation into an immutable [`Settings`](@ref).
Hard errors name the offending key; unknown keys produce warnings.
"""
module Config

using DocStringExtensions: TYPEDFIELDS, TYPEDSIGNATURES
using ..WaitingTimes: MAX_DIGITS, TIME_UNITS, QuantizedSeries, threshold, check_digits,
                      on_grid
using ..Provenance: effective_config
using TOML: TOML

export Settings, load_settings, threshold_list, threshold_decimals, KNOWN_KEYS,
       PREPROCESSING_OPS, step_tag

"""
    Settings

Fully parsed and validated pipeline configuration. Constructed by keyword only
through [`load_settings`](@ref).

$(TYPEDFIELDS)
"""
Base.@kwdef struct Settings
    "directory of the configuration file; relative paths resolve against it"
    config_dir::String
    # input
    "absolute path of the input file"
    input_path::String
    "`:csv`, `:dat`, `:arrow` or `:tick`"
    input_format::Symbol
    "dataset descriptor slug, or empty"
    dataset::String
    "absolute path of the source descriptor (TOML) of the input, or empty"
    source_descriptor::String
    "value column, by 1-based index or name"
    value_column::Union{Int, String}
    "time column, by index or name; `nothing` for the sample index; for `format = \"tick\"` the default is `\"time_ns\"`"
    time_column::Union{Nothing, Int, String}
    "time unit of the series, one of `TIME_UNITS`; for `format = \"tick\"` the default is `:nanosecond`"
    time_unit::Symbol
    "time axis of the collection: `:elapsed` (the clock of the input) or `:index` (row ordinal)"
    time_axis::Symbol
    "`Dates` format of textual time stamps, or empty for ISO 8601 / numeric"
    time_format::String
    "unit of numeric time stamps in the file; for `format = \"tick\"` the default is `:nanosecond`, the only value admitted"
    epoch_unit::Symbol
    "field delimiter, or empty for the format's default"
    delimiter::String
    "whether the file has a header row"
    header::Bool
    "`:drop` or `:error`"
    missing_policy::Symbol
    "`:error`, `:first`, `:last` or `:mean`"
    tie_policy::Symbol
    # preprocessing
    "ordered preprocessing steps, each a table with an `op` key"
    steps::Vector{Dict{String, Any}}
    # gaps
    "path of a TOML file declaring gap intervals, or empty"
    declared_gaps::String
    "`:none` or `:cadence`"
    gap_detect::Symbol
    "cadence for `:cadence` detection"
    gap_cadence::Int
    "distribution mode, `:elapsed` or `:exact`"
    mode::Symbol
    # quantization
    "decimal digits of the grid; `nothing` for `\"auto\"`, resolved by `prepare`"
    digits::Union{Nothing, Int}
    "largest `digits` the automatic choice may return"
    auto_max_digits::Int
    "Kolmogorov–Smirnov tolerance of the automatic choice"
    auto_tolerance::Float64
    "largest ratio of grid step to increment scale in the automatic choice"
    auto_step_ratio::Float64
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
    "seed of the random choice of reference-check thresholds"
    seed::Int
    "`:debug`, `:info` or `:warn`"
    log_level::Symbol
    "seconds between resume checkpoints of a session (index, summary and catalogue rewritten); 0 after every chunk"
    checkpoint_seconds::Float64
    "effective configuration as parsed"
    raw::Dict{String, Any}
end

"recognised keys per section, for typo warnings"
const KNOWN_KEYS = Dict(
    "" => ["base_config", "input", "preprocessing", "gaps", "quantization", "thresholds",
        "algorithm", "limits", "output", "run"],
    "input" => ["path", "format", "dataset", "source_descriptor",
        "value_column", "time_column", "time_unit", "time_axis",
        "time_format", "epoch_unit", "delimiter", "header", "missing_policy", "tie_policy"],
    "preprocessing" => ["steps"],
    "gaps" => ["declared", "detect", "cadence", "mode"],
    "quantization" => ["digits", "auto_max_digits", "auto_tolerance", "auto_step_ratio"],
    "thresholds" => ["mode", "min", "max", "step", "points_per_decade", "values"],
    "algorithm" =>
        ["search", "backend", "chunk_size", "reference_checks", "reference_kernel"],
    "limits" => ["max_ram_gb", "max_vram_gb", "max_reference_work"],
    "output" => ["root", "format", "store_waiting_times", "overwrite"],
    "run" => ["seed", "log_level", "checkpoint_seconds"]
)

"""
A preprocessing operation: its accepted parameter keys, the default of every
optional key, the validator of a step table and the tag it contributes to the
series slug.

$(TYPEDFIELDS)
"""
struct PreprocessingOp
    "accepted parameter keys, `op` excluded"
    keys::Vector{String}
    "default of every optional key; required keys are absent"
    defaults::Dict{String, Any}
    "validator `(step::AbstractDict, where_::AbstractString) -> nothing`"
    validate::Function
    "slug tag `(step::AbstractDict) -> String`"
    tag::Function
end

"preprocessing operations by name"
const PREPROCESSING_OPS = Dict{String, PreprocessingOp}(
    "select_range" => PreprocessingOp(["from", "to"],
        Dict{String, Any}("from" => -Inf, "to" => Inf),
        function (step, where_)
            haskey(step, "from") && as_float(step["from"], where_, "from")
            haskey(step, "to") && as_float(step["to"], where_, "to")
            return nothing
        end,
        step -> "range"),
    "exclude_intervals" => PreprocessingOp(["intervals", "splice"],
        Dict{String, Any}("splice" => true),
        function (step, where_)
            ivs = require(step, where_, "intervals")
            ivs isa AbstractVector &&
            all(iv -> iv isa AbstractVector && length(iv) == 2, ivs) ||
                throw(ArgumentError("[$where_] intervals must be an array of [start, stop] pairs"))
            haskey(step, "splice") && as_bool(step["splice"], where_, "splice")
            return nothing
        end,
        step -> "cut"),
    "round" => PreprocessingOp(["digits"],
        Dict{String, Any}(),
        function (step, where_)
            as_int(require(step, where_, "digits"), where_,
                "digits"; min = 0, max = MAX_DIGITS)
            return nothing
        end,
        step -> "round" * string(step["digits"])),
    "trailing_mean_fluctuations" =>
        let defaults = Dict{String, Any}(
                "denominator" => "mean", "offset" => "none", "on_nonpositive" => "error")
            PreprocessingOp(
                ["window", "denominator", "offset", "on_nonpositive"], defaults,
                function (step, where_)
                    as_int(require(step, where_, "window"), where_, "window"; min = 1)
                    denominator = as_symbol(
                        get(step, "denominator", "mean"), where_,
                        "denominator", (:mean, :scale, :none))
                    offset = get(step, "offset", "none")
                    if offset isa AbstractString
                        as_symbol(offset, where_, "offset", (:none, :auto))
                    else
                        as_float(offset, where_, "offset")
                    end
                    (offset == "none" || denominator === :mean) ||
                        throw(ArgumentError("[$where_] offset applies to denominator = \"mean\" only"))
                    as_symbol(get(step, "on_nonpositive", "error"), where_,
                        "on_nonpositive", (:error, :missing))
                    return nothing
                end,
                function (step)
                    denominator = String(get(step, "denominator", defaults["denominator"]))
                    suffix = denominator == "mean" ? "" :
                             denominator == "scale" ? "scaled" : "abs"
                    return "trailing" * string(step["window"]) * suffix
                end)
        end,
    "log_returns" => PreprocessingOp(String[], Dict{String, Any}(),
        (step, where_) -> nothing, step -> "logret"),
    "log_levels" => PreprocessingOp(["reference"],
        Dict{String, Any}("reference" => "first"),
        function (step, where_)
            reference = get(step, "reference", "first")
            if reference isa AbstractString
                as_symbol(reference, where_, "reference", (:first,))
            else
                r = as_float(reference, where_, "reference")
                r > 0 ||
                    throw(ArgumentError("[$where_] reference must be positive, got $r"))
            end
            return nothing
        end,
        step -> "loglevels"),
    "differences" => PreprocessingOp(String[], Dict{String, Any}(),
        (step, where_) -> nothing, step -> "diff"),
    "detrend_moving_average" => PreprocessingOp(["window"],
        Dict{String, Any}(),
        function (step, where_)
            w = as_int(require(step, where_, "window"), where_, "window"; min = 1)
            isodd(w) || throw(ArgumentError("[$where_] window must be odd, got $w"))
            return nothing
        end,
        step -> "detrend" * string(step["window"])),
    "clip_quantile" => PreprocessingOp(["q", "splice"],
        Dict{String, Any}("splice" => false),
        function (step, where_)
            q = as_float(require(step, where_, "q"), where_, "q"; min = 0.0, max = 1.0)
            q > 0 || throw(ArgumentError("[$where_] q must be positive"))
            haskey(step, "splice") && as_bool(step["splice"], where_, "splice")
            return nothing
        end,
        step -> "clip" * string(step["q"])),
    "clip_sigma" =>
        let defaults = Dict{String, Any}(
                "k" => 3, "center" => "mean", "scale" => "std", "splice" => false)
            PreprocessingOp(["k", "center", "scale", "splice"], defaults,
                function (step, where_)
                    k_ = as_float(get(step, "k", 3.0), where_, "k")
                    k_ > 0 || throw(ArgumentError("[$where_] k must be positive, got $k_"))
                    as_symbol(get(step, "center", "mean"), where_, "center",
                        (:mean, :median))
                    as_symbol(get(step, "scale", "std"), where_, "scale", (
                        :std, :mad))
                    haskey(step, "splice") && as_bool(step["splice"], where_, "splice")
                    return nothing
                end,
                step -> "sigma" * string(get(step, "k", defaults["k"])))
        end,
    "clip_extremes" =>
        let defaults = Dict{String, Any}("fraction" => 0.004, "splice" => false)
            PreprocessingOp(["fraction", "digits", "splice"], defaults,
                function (step, where_)
                    f = as_float(get(step, "fraction", 0.004), where_, "fraction")
                    0 < f < 1 ||
                        throw(ArgumentError("[$where_] fraction must lie in (0, 1), got $f"))
                    as_int(require(step, where_, "digits"), where_, "digits";
                        min = 0, max = MAX_DIGITS)
                    haskey(step, "splice") && as_bool(step["splice"], where_, "splice")
                    return nothing
                end,
                step -> "prune" * string(get(step, "fraction", defaults["fraction"])))
        end,
    "collapse_ties" => PreprocessingOp(["policy"],
        Dict{String, Any}(),
        function (step, where_)
            as_symbol(require(step, where_, "policy"), where_, "policy",
                (:error, :first, :last, :mean))
            return nothing
        end,
        step -> "ties")
)

"""
$(TYPEDSIGNATURES)

Tag that the preprocessing step table `step` contributes to the series slug,
e.g. `"trailing30"` for `{op = "trailing_mean_fluctuations", window = 30}`.
"""
step_tag(step::AbstractDict) = PREPROCESSING_OPS[String(step["op"])].tag(step)

"""
Validate preprocessing step `k`: the operation `name` must be one of
[`PREPROCESSING_OPS`](@ref), keys it does not accept produce warnings, and its
parameters (types, choices, bounds) are checked so that a run cannot start
from a step it cannot execute.
"""
function validate_step(step::AbstractDict, name::AbstractString, k::Integer)
    where_ = "preprocessing.steps[$k]"
    haskey(PREPROCESSING_OPS, name) || throw(ArgumentError(
        "[preprocessing] steps[$k].op = $(repr(name)) is not one of $(join(sort(collect(keys(PREPROCESSING_OPS))), ", "))",
    ))
    op = PREPROCESSING_OPS[name]
    for key in keys(step)
        key == "op" || key in op.keys ||
            @warn "unknown preprocessing step key ignored" op = name key
    end
    op.validate(step, where_)
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
    config_file = abspath(path)
    isfile(config_file) ||
        throw(ArgumentError("configuration file not found: $config_file"))
    config_dir = dirname(config_file)
    raw = effective_config(config_file)
    warn_unknown_keys(raw, "")
    for name in keys(KNOWN_KEYS)
        isempty(name) && continue
        haskey(raw, name) && raw[name] isa AbstractDict &&
            warn_unknown_keys(raw[name], name)
    end

    input = parse_input(raw, config_dir)
    preprocessing = parse_preprocessing(raw)
    gaps = parse_gaps(raw, config_dir)
    quantization = parse_quantization(raw)
    thresholds = parse_thresholds(raw, quantization.digits, quantization.auto_max_digits)
    algorithm = parse_algorithm(raw)
    limits = parse_limits(raw)
    output = parse_output(raw, config_dir, output_dir)
    run = parse_run(raw)

    warn_ignored_keys(section(raw, "algorithm"), section(raw, "gaps"),
        section(raw, "thresholds"); search = algorithm.search,
        reference_kernel = algorithm.reference_kernel, gap_detect = gaps.gap_detect,
        threshold_mode = thresholds.threshold_mode)

    return Settings(; config_dir, input..., preprocessing..., gaps..., quantization...,
        thresholds..., algorithm..., limits..., output..., run..., raw)
end

"`[input]` section of a configuration, validated"
function parse_input(raw, config_dir)
    inp = section(raw, "input")
    input_path = resolve_path(
        as_string(require(inp, "input", "path"), "input", "path"), config_dir)
    isfile(input_path) || throw(ArgumentError("[input] path does not exist: $input_path"))
    input_format = as_symbol(get(inp, "format", "csv"), "input", "format",
        (:csv, :dat, :arrow, :tick))
    tick = input_format === :tick
    dataset = as_string(get(inp, "dataset", ""), "input", "dataset")
    source_raw = as_string(get(inp, "source_descriptor", ""), "input", "source_descriptor")
    source_descriptor = isempty(source_raw) ? "" : resolve_path(source_raw, config_dir)
    isempty(source_descriptor) || validate_source_descriptor(source_descriptor)
    value_column = as_column(require(inp, "input", "value_column"), "input", "value_column")
    time_column_raw = get(inp, "time_column", tick ? "time_ns" : "")
    time_column = time_column_raw == "" ? nothing :
                  as_column(time_column_raw, "input", "time_column")
    time_unit = as_symbol(get(inp, "time_unit", tick ? "nanosecond" : "sample"), "input",
        "time_unit", TIME_UNITS)
    time_column === nothing && time_unit !== :sample &&
        throw(ArgumentError(
            "[input] time_unit = :$time_unit requires a time_column",
        ))
    time_column !== nothing && time_unit === :sample &&
        throw(ArgumentError(
            "[input] a time_column requires a time_unit other than \"sample\"",
        ))
    time_axis = as_symbol(get(inp, "time_axis", "elapsed"), "input", "time_axis",
        (:elapsed, :index))
    time_format = as_string(get(inp, "time_format", ""), "input", "time_format")
    epoch_unit = as_symbol(get(inp, "epoch_unit", tick ? "nanosecond" : "second"), "input",
        "epoch_unit", TIME_UNITS[2:end])
    tick && epoch_unit !== :nanosecond &&
        throw(ArgumentError(
            "[input] epoch_unit must be \"nanosecond\" for format = \"tick\", got \"$epoch_unit\"",
        ))
    delimiter = as_string(get(inp, "delimiter", ""), "input", "delimiter")
    header = as_bool(get(inp, "header", true), "input", "header")
    missing_policy = as_symbol(get(inp, "missing_policy", "drop"), "input",
        "missing_policy", (:drop, :error))
    tie_policy = as_symbol(get(inp, "tie_policy", "error"), "input", "tie_policy",
        (:error, :first, :last, :mean))
    return (; input_path, input_format, dataset, source_descriptor, value_column,
        time_column, time_unit, time_axis, time_format, epoch_unit, delimiter, header,
        missing_policy, tie_policy)
end

"`[preprocessing]` section of a configuration, validated"
function parse_preprocessing(raw)
    pre = section(raw, "preprocessing")
    steps_raw = get(pre, "steps", Any[])
    steps_raw isa AbstractVector ||
        throw(ArgumentError("[preprocessing] steps must be an array of tables"))
    steps = Vector{Dict{String, Any}}()
    for (k, step) in enumerate(steps_raw)
        step isa AbstractDict ||
            throw(ArgumentError("[preprocessing] steps[$k] must be a table with an op key"))
        op = as_string(require(step, "preprocessing.steps[$k]", "op"), "preprocessing", "op")
        validate_step(step, op, k)
        push!(steps, Dict{String, Any}(step))
    end
    return (; steps)
end

"`[gaps]` section of a configuration, validated"
function parse_gaps(raw, config_dir)
    gaps = section(raw, "gaps")
    declared = as_string(get(gaps, "declared", ""), "gaps", "declared")
    declared_gaps = isempty(declared) ? "" : resolve_path(declared, config_dir)
    isempty(declared_gaps) || isfile(declared_gaps) ||
        throw(ArgumentError("[gaps] declared file does not exist: $declared_gaps"))
    gap_detect = as_symbol(get(gaps, "detect", "cadence"), "gaps", "detect",
        (:none, :cadence))
    gap_cadence = as_int(get(gaps, "cadence", 1), "gaps", "cadence"; min = 1)
    mode = as_symbol(get(gaps, "mode", "elapsed"), "gaps", "mode", (:elapsed, :exact))
    return (; declared_gaps, gap_detect, gap_cadence, mode)
end

"`[quantization]` section of a configuration, validated"
function parse_quantization(raw)
    quant = section(raw, "quantization")
    digits_raw = require(quant, "quantization", "digits")
    digits = if digits_raw isa AbstractString
        lowercase(digits_raw) == "auto" || throw(ArgumentError(
            "[quantization] digits must be an integer in 0:$(MAX_DIGITS) or \"auto\", got $(repr(digits_raw))",
        ))
        nothing
    else
        check_digits(as_int(
            digits_raw, "quantization", "digits"; min = 0, max = MAX_DIGITS))
    end
    auto_max_digits = as_int(get(quant, "auto_max_digits", 8),
        "quantization", "auto_max_digits"; min = 0, max = 14)
    auto_tolerance = as_float(get(quant, "auto_tolerance", 1e-3),
        "quantization", "auto_tolerance"; min = 0.0, max = 1.0)
    0 < auto_tolerance < 1 ||
        throw(ArgumentError("[quantization] auto_tolerance must lie in (0, 1)"))
    auto_step_ratio = as_float(get(quant, "auto_step_ratio", 0.1),
        "quantization", "auto_step_ratio"; min = 0.0, max = 1.0)
    auto_step_ratio > 0 ||
        throw(ArgumentError("[quantization] auto_step_ratio must lie in (0, 1]"))
    return (; digits, auto_max_digits, auto_tolerance, auto_step_ratio)
end

"`[thresholds]` section of a configuration, validated against the grid of `digits`"
function parse_thresholds(raw, digits, auto_max_digits)
    thr = section(raw, "thresholds")
    threshold_mode = as_symbol(get(thr, "mode", "linear"), "thresholds", "mode",
        (:linear, :log, :explicit))
    threshold_min = as_float(get(thr, "min", 0.0), "thresholds", "min"; min = 0.0)
    threshold_max = as_float(get(thr, "max", 0.0), "thresholds", "max"; min = 0.0)
    threshold_step = as_float(get(thr, "step", 0.0), "thresholds", "step"; min = 0.0)
    points_per_decade = as_int(
        get(thr, "points_per_decade", 10), "thresholds", "points_per_decade"; min = 1)
    values_raw = get(thr, "values", Any[])
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
    grid_values = threshold_grid_values(threshold_mode, threshold_min, threshold_max,
        threshold_step, threshold_values)
    if digits === nothing
        needed = maximum(decimals, grid_values; init = 0)
        needed <= auto_max_digits || throw(ArgumentError(
            "[thresholds] the grid needs $needed decimals, above [quantization] auto_max_digits = $auto_max_digits",
        ))
    else
        for v in grid_values
            on_grid(v, digits) ||
                throw(ArgumentError("[thresholds] $v is not on the 10^-$digits grid"))
        end
    end
    return (; threshold_mode, threshold_min, threshold_max, threshold_step,
        points_per_decade, threshold_values)
end

"`[algorithm]` section of a configuration, validated"
function parse_algorithm(raw)
    alg = section(raw, "algorithm")
    search = as_symbol(get(alg, "search", "segment_tree"), "algorithm", "search",
        (:naive, :guarded, :segment_tree, :fenwick_sweep, :streaming, :device))
    backend = as_symbol(get(alg, "backend", "none"), "algorithm", "backend",
        (:none, :auto, :cuda, :oneapi, :amdgpu, :metal))
    chunk_size = as_int(get(alg, "chunk_size", 4096), "algorithm", "chunk_size"; min = 1)
    reference_checks = as_int(get(alg, "reference_checks", 2),
        "algorithm", "reference_checks"; min = 0)
    reference_kernel = as_symbol(get(alg, "reference_kernel", "naive"),
        "algorithm", "reference_kernel", (:naive, :guarded, :device))
    return (; search, backend, chunk_size, reference_checks, reference_kernel)
end

"`[limits]` section of a configuration, validated"
function parse_limits(raw)
    lim = section(raw, "limits")
    max_ram_gb = as_float(get(lim, "max_ram_gb", 16.0), "limits", "max_ram_gb"; min = 0.0)
    max_vram_gb = as_float(get(lim, "max_vram_gb", 8.0), "limits", "max_vram_gb"; min = 0.0)
    max_reference_work = as_float(
        get(lim, "max_reference_work", 1e12), "limits", "max_reference_work"; min = 0.0)
    return (; max_ram_gb, max_vram_gb, max_reference_work)
end

"`[output]` section of a configuration, validated; `output_dir` overrides `root`"
function parse_output(raw, config_dir, output_dir)
    out = section(raw, "output")
    output_root = if output_dir === nothing
        resolve_path(as_string(get(out, "root", "data"), "output", "root"), config_dir)
    else
        abspath(output_dir)
    end
    output_format = as_symbol(get(out, "format", "arrow"), "output", "format",
        (:csv, :arrow))
    store_waiting_times = as_bool(
        get(out, "store_waiting_times", false), "output", "store_waiting_times")
    overwrite = as_bool(get(out, "overwrite", false), "output", "overwrite")
    return (; output_root, output_format, store_waiting_times, overwrite)
end

"`[run]` section of a configuration, validated"
function parse_run(raw)
    run = section(raw, "run")
    seed = as_int(get(run, "seed", 12345), "run", "seed")
    log_level = as_symbol(get(run, "log_level", "info"), "run", "log_level",
        (:debug, :info, :warn))
    checkpoint_seconds = as_float(get(run, "checkpoint_seconds", 10.0), "run",
        "checkpoint_seconds"; min = 0.0)
    return (; seed, log_level, checkpoint_seconds)
end

"a source descriptor must exist and parse as a TOML table"
function validate_source_descriptor(path::AbstractString)
    isfile(path) ||
        throw(ArgumentError("[input] source_descriptor does not exist: $path"))
    TOML.tryparsefile(path) isa TOML.ParserError &&
        throw(ArgumentError("[input] source_descriptor is not valid TOML: $path"))
    return path
end

"""
Warn about keys present in the raw `[algorithm]`, `[gaps]` and `[thresholds]`
tables that the active modes ignore.
"""
function warn_ignored_keys(alg::AbstractDict, gaps::AbstractDict, thr::AbstractDict;
        search::Symbol, reference_kernel::Symbol, gap_detect::Symbol, threshold_mode::Symbol)
    haskey(alg, "chunk_size") && search ∉ (:naive, :guarded, :segment_tree) &&
        @warn "[algorithm] chunk_size is ignored under search = \"$search\""
    haskey(alg, "backend") && alg["backend"] != "none" && search !== :device &&
        reference_kernel !== :device &&
        @warn "[algorithm] backend is ignored under search = \"$search\" and reference_kernel = \"$reference_kernel\""
    haskey(gaps, "cadence") && gap_detect === :none &&
        @warn "[gaps] cadence is ignored under detect = \"none\""
    for (key, used_in) in ("step" => :linear, "points_per_decade" => :log, "values" =>
        :explicit)
        haskey(thr, key) && threshold_mode !== used_in &&
            @warn "[thresholds] $key is ignored under mode = \"$threshold_mode\""
    end
    return nothing
end

"decimals needed to place `value` on a grid (at most `MAX_DIGITS`)"
function decimals(value::Real)
    for d in 0:MAX_DIGITS
        on_grid(value, d) && return d
    end
    throw(ArgumentError("$value has more than $(MAX_DIGITS) decimals"))
end

"threshold values that must lie on the grid: the explicit values, or the grid ends and step"
function threshold_grid_values(mode, min, max, step, values)
    mode === :explicit && return values
    mode === :log && return [min, max]
    return [min, max, step]
end

"""
$(TYPEDSIGNATURES)

Decimals the configured threshold grid needs: the lower bound of an automatic
`digits` choice.
"""
function threshold_decimals(settings::Settings)
    values = threshold_grid_values(settings.threshold_mode, settings.threshold_min,
        settings.threshold_max, settings.threshold_step, settings.threshold_values)
    return maximum(decimals, values; init = 0)
end

"""
$(TYPEDSIGNATURES)

Sorted distinct thresholds of the configured grid on the grid of `s`. Points
of a logarithmic grid are rounded to the nearest grid integer (at least one
step), and that grid always ends at `max`.
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
