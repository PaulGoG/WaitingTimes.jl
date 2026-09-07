# Search kernels. Every kernel writes τ[n] for each index into its own slot
# (sentinel 0 = no observed passage), so results are deterministic and
# comparable with == across kernels and backends.

"""
Supertype of the search algorithms computing waiting times.
"""
abstract type AbstractSearch end

"""
    NaiveSearch(; chunk_size = 4096)

The definition, verbatim: for each index scan forward until the first value at
least `δ` above it. Cost ``O(\\sum_n \\tau_n)``, worst case ``O(N^2)``. This is
the permanent correctness oracle for every other kernel. Indices are processed
in chunks of `chunk_size` under dynamic scheduling, because the cost per index
is heavy-tailed.
"""
struct NaiveSearch <: AbstractSearch
    chunk_size::Int
    function NaiveSearch(; chunk_size::Integer = 4096)
        chunk_size >= 1 ||
            throw(ArgumentError("chunk_size must be positive, got $chunk_size"))
        return new(Int(chunk_size))
    end
end

"""
    GuardedSearch(; chunk_size = 4096)

The naive scan preceded by an O(1) censoring proof: with the suffix maximum
``M_n = \\max_{m > n} q_m`` computed once per series, an index whose target
exceeds ``M_{n+1}`` has no passage and is skipped. Nothing else differs from
[`NaiveSearch`](@ref).
"""
struct GuardedSearch <: AbstractSearch
    chunk_size::Int
    function GuardedSearch(; chunk_size::Integer = 4096)
        chunk_size >= 1 ||
            throw(ArgumentError("chunk_size must be positive, got $chunk_size"))
        return new(Int(chunk_size))
    end
end

"""
    SearchWorkspace{Tv}

Series-level precomputation reused across thresholds.

$(TYPEDFIELDS)
"""
struct SearchWorkspace{Tv <: Integer}
    "``M_n = \\max_{m \\ge n} q_m``"
    suffix_maximum::Vector{Tv}
end

"""
$(TYPEDSIGNATURES)

Suffix maxima ``M_n = \\max_{m \\ge n} q_m`` of the values.
"""
function suffix_maximum(q::AbstractVector{Tv}) where {Tv}
    N = length(q)
    M = Vector{Tv}(undef, N)
    N == 0 && return M
    @inbounds M[N] = q[N]
    @inbounds for n in (N - 1):-1:1
        M[n] = max(q[n], M[n + 1])
    end
    return M
end

"""
$(TYPEDSIGNATURES)

Workspace for `alg` on the series `s`; `NaiveSearch` needs none.
"""
workspace(::NaiveSearch, ::QuantizedSeries) = nothing
workspace(::GuardedSearch, s::QuantizedSeries) = SearchWorkspace(suffix_maximum(s.values))

"""
$(TYPEDSIGNATURES)

Threshold of `s` from a real value or decimal string on the grid of `s`, with
the integer type of the values.
"""
function threshold(δ::Union{Real, AbstractString}, s::QuantizedSeries{Tv}) where {Tv}
    Threshold{Tv}(threshold(δ, s.digits).d, s.digits)
end

"""
$(TYPEDSIGNATURES)

Verify that `δ` lives on the grid of `s` and that `q_n + d` cannot overflow the
value type; return `d` as that type.
"""
function check_threshold(s::QuantizedSeries{Tv}, δ::Threshold) where {Tv}
    δ.digits == s.digits || throw(ArgumentError(
        "threshold has $(δ.digits) digits, series has $(s.digits)",
    ))
    headroom = Int128(typemax(Tv)) - Int128(maximum(s.values))
    Int128(δ.d) <= headroom || throw(OverflowError(
        "threshold $(format_threshold(δ)) exceeds the headroom of $Tv values; rebuild the " *
        "series with narrow = false",
    ))
    return Tv(δ.d)
end

@inline function scan_forward(q::AbstractVector{Tv}, t::AbstractVector{Tt}, i::Int, d::Tv,
        stop::Int) where {Tv, Tt}
    target = q[i] + d
    @inbounds for j in (i + 1):stop
        q[j] >= target && return t[j] - t[i]
    end
    return zero(Tt)
end

"""
$(TYPEDSIGNATURES)

Waiting times of every index of `s` at threshold `δ` into `τ` (length `N`),
with `0` where no passage is observed. `workspace` is built on demand for
kernels that need one. Returns `τ`.
"""
function waiting_times!(τ::AbstractVector{Tt}, s::QuantizedSeries{Tv, Tt}, δ::Threshold,
        alg::NaiveSearch; workspace = nothing) where {Tv, Tt}
    q, t = s.values, s.times
    N = length(q)
    length(τ) == N || throw(DimensionMismatch("τ has length $(length(τ)), series has $N"))
    d = check_threshold(s, δ)
    τ[N] = zero(Tt)
    tforeach(1:(N - 1); chunksize = alg.chunk_size) do i
        @inbounds τ[i] = scan_forward(q, t, i, d, N)
    end
    return τ
end

function waiting_times!(τ::AbstractVector{Tt}, s::QuantizedSeries{Tv, Tt}, δ::Threshold,
        alg::GuardedSearch; workspace::Union{Nothing, SearchWorkspace{Tv}} = nothing) where {
        Tv, Tt}
    q, t = s.values, s.times
    N = length(q)
    length(τ) == N || throw(DimensionMismatch("τ has length $(length(τ)), series has $N"))
    d = check_threshold(s, δ)
    ws = workspace === nothing ? WaitingTimes.workspace(alg, s) : workspace
    M = ws.suffix_maximum
    length(M) == N || throw(DimensionMismatch("workspace was built for another series"))
    τ[N] = zero(Tt)
    tforeach(1:(N - 1); chunksize = alg.chunk_size) do i
        @inbounds τ[i] = q[i] + d > M[i + 1] ? zero(Tt) : scan_forward(q, t, i, d, N)
    end
    return τ
end

"""
$(TYPEDSIGNATURES)

Allocating form of [`waiting_times!`](@ref). `δ` may be a [`Threshold`](@ref),
a real value or a decimal string on the grid of `s`.
"""
function waiting_times(s::QuantizedSeries{Tv, Tt}, δ::Threshold,
        alg::AbstractSearch = SegmentTreeSearch(); workspace = nothing) where {Tv, Tt}
    τ = Vector{Tt}(undef, length(s))
    return waiting_times!(τ, s, δ, alg; workspace = workspace)
end
function waiting_times(s::QuantizedSeries, δ::Union{Real, AbstractString},
        alg::AbstractSearch = SegmentTreeSearch(); kwargs...)
    waiting_times(s, threshold(δ, s), alg; kwargs...)
end
