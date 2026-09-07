# Decimal integer grid: values and thresholds as integers scaled by 10^digits.

"""
Largest number of decimal digits accepted for the grid; beyond it the scale
factor 10^digits is no longer exactly representable in Float64 arithmetic.
"""
const MAX_DIGITS = 15

"""
Magnitude below which quantised values are narrowed to `Int32`. The margin of
2^30 leaves room for every threshold that can still produce a passage.
"""
const INT32_NARROWING_LIMIT = 2^30

function check_digits(digits::Integer)
    0 <= digits <= MAX_DIGITS ||
        throw(ArgumentError("digits must lie in 0:$(MAX_DIGITS), got $digits"))
    return Int(digits)
end

"""
    Threshold{T<:Integer}

Threshold ``\\delta`` on the decimal grid: the integer `d` equals
``\\delta \\cdot 10^{\\mathrm{digits}}``. Thresholds are stored and compared as
integers and rendered with exactly `digits` decimals; a floating-point δ never
enters a file name or an identifier.

$(TYPEDFIELDS)
"""
struct Threshold{T <: Integer}
    "threshold scaled to the grid, non-negative"
    d::T
    "decimal digits of the grid"
    digits::Int
    function Threshold{T}(d::Integer, digits::Integer) where {T <: Integer}
        d >= 0 || throw(ArgumentError("thresholds are non-negative, got d = $d"))
        return new{T}(T(d), check_digits(digits))
    end
end

Threshold(d::T, digits::Integer) where {T <: Integer} = Threshold{T}(d, digits)

"""
$(TYPEDSIGNATURES)

Integer grid coordinate of the real threshold `δ` for the given `digits`.
Throws `ArgumentError` when `δ` is negative or not a multiple of
``10^{-\\mathrm{digits}}`` (to within `1e-6` grid units).
"""
function threshold_integer(δ::Real, digits::Integer)
    digits = check_digits(digits)
    isfinite(δ) || throw(ArgumentError("threshold must be finite, got $δ"))
    δ >= 0 || throw(ArgumentError("thresholds are non-negative, got $δ"))
    scaled = Float64(δ) * 10.0^digits
    k = round(scaled)
    abs(scaled - k) <= 1e-6 || throw(ArgumentError(
        "threshold $δ is not on the 10^-$digits grid; choose a multiple of $(10.0^-digits)",
    ))
    k < 9.0e18 || throw(ArgumentError("threshold $δ overflows the integer grid"))
    return Int64(k)
end

"""
$(TYPEDSIGNATURES)

Threshold on the grid with `digits` decimals, from a real value (validated to
lie on the grid) or from a decimal string (parsed exactly).
"""
threshold(δ::Real, digits::Integer) = Threshold(threshold_integer(δ, digits), digits)
threshold(δ::AbstractString, digits::Integer) = parse_threshold(δ, digits)

"""
$(TYPEDSIGNATURES)

Fixed-decimal rendering of a grid integer with exactly `digits` decimals:
`format_threshold(5, 4) == "0.0005"`, `format_threshold(25000, 0) == "25000"`.
"""
function format_threshold(d::Integer, digits::Integer)
    digits = check_digits(digits)
    d >= 0 || throw(ArgumentError("thresholds are non-negative, got d = $d"))
    digits == 0 && return string(d)
    whole, frac = divrem(Int64(d), Int64(10)^digits)
    return string(whole, '.', lpad(string(frac), digits, '0'))
end
format_threshold(δ::Threshold) = format_threshold(δ.d, δ.digits)

"""
$(TYPEDSIGNATURES)

Exact parse of a non-negative decimal string with at most `digits` decimals
into a [`Threshold`](@ref); the inverse of [`format_threshold`](@ref).
"""
function parse_threshold(text::AbstractString, digits::Integer)
    digits = check_digits(digits)
    s = strip(text)
    m = match(r"^(\d+)(?:\.(\d*))?$", s)
    m === nothing &&
        throw(ArgumentError("not a non-negative decimal literal: $(repr(text))"))
    whole = something(m.captures[1])
    frac = something(m.captures[2], "")
    length(frac) <= digits || throw(ArgumentError(
        "$(repr(text)) carries $(length(frac)) decimals but the grid has $digits",
    ))
    frac_padded = rpad(frac, digits, '0')
    d = parse(Int64, whole) * Int64(10)^digits +
        (digits == 0 ? 0 : parse(Int64, frac_padded))
    return Threshold(d, digits)
end

function Base.show(io::IO, δ::Threshold)
    print(io, "Threshold(", format_threshold(δ), ", digits = ", δ.digits, ")")
end
Base.:(==)(a::Threshold, b::Threshold) = a.d == b.d && a.digits == b.digits
Base.hash(δ::Threshold, h::UInt) = hash((δ.d, δ.digits), h)
function Base.isless(a::Threshold, b::Threshold)
    a.digits == b.digits ? isless(a.d, b.d) :
    throw(ArgumentError("thresholds on different grids are not comparable"))
end

"""
$(TYPEDSIGNATURES)

Real value of the threshold, for labels only (never for arithmetic or names).
"""
Base.float(δ::Threshold) = δ.d / 10.0^δ.digits

"""
$(TYPEDSIGNATURES)

Quantise real values to the decimal grid with `digits` decimals. Each value is
first rounded with `round(x; digits)` (half to even, the legacy convention) and
the result is scaled to the integer numerator, so grid assignment is identical
to the legacy code's rounding. Non-finite values are rejected.
"""
function quantize(x::AbstractVector{<:Real}, digits::Integer)
    digits = check_digits(digits)
    scale = 10.0^digits
    q = Vector{Int64}(undef, length(x))
    for (i, v) in enumerate(x)
        isfinite(v) || throw(ArgumentError("non-finite value $v at index $i"))
        rounded = round(Float64(v); digits = digits) * scale
        abs(rounded) < 9.0e18 || throw(ArgumentError("value $v overflows the integer grid"))
        q[i] = round(Int64, rounded)
    end
    return q
end

"""
$(TYPEDSIGNATURES)

Narrow a vector of grid integers to `Int32` when every magnitude is below
`INT32_NARROWING_LIMIT`; otherwise return it unchanged.
"""
function narrow_integer(q::AbstractVector{Int64})
    (isempty(q) || maximum(abs, q) < INT32_NARROWING_LIMIT) && return Int32.(q)
    return Vector{Int64}(q)
end
