# Segment-tree search: a maximum tree over positions answers "leftmost position
# at or after n+1 with value at least the target" in O(log N); the tree is built
# once per series and read-only during queries, so indices are independent.

"""
    SegmentTreeSearch(; chunk_size = 4096)

Default fast kernel. A maximum segment tree over the positions of the series
answers, for each index, the leftmost later position whose value reaches the
target in ``O(\\log N)``: climb to the first right sibling whose maximum
qualifies, then descend to its leftmost qualifying leaf. The tree is built
once per series (`workspace`) and is read-only during queries, so the loop
over indices runs in parallel exactly like the reference kernel's. Results equal
[`NaiveSearch`](@ref) bit for bit.
"""
struct SegmentTreeSearch <: AbstractSearch
    chunk_size::Int
    function SegmentTreeSearch(; chunk_size::Integer = 4096)
        chunk_size >= 1 ||
            throw(ArgumentError("chunk_size must be positive, got $chunk_size"))
        return new(Int(chunk_size))
    end
end

"""
    MaxTree{Tv}

Maximum segment tree over `N` positions padded to `P = nextpow(2, N)` leaves;
`tree[P + i - 1]` holds ``q_i``, padding leaves hold `typemin`.

$(TYPEDFIELDS)
"""
struct MaxTree{Tv <: Integer}
    "tree nodes, root at 1, children of `i` at `2i` and `2i + 1`"
    tree::Vector{Tv}
    "number of leaves (power of two)"
    P::Int
    "number of positions"
    N::Int
end

function MaxTree(q::AbstractVector{Tv}) where {Tv <: Integer}
    N = length(q)
    P = max(1, nextpow(2, N))
    tree = fill(typemin(Tv), 2P)
    @inbounds for i in 1:N
        tree[P + i - 1] = q[i]
    end
    @inbounds for i in (P - 1):-1:1
        tree[i] = max(tree[2i], tree[2i + 1])
    end
    return MaxTree{Tv}(tree, P, N)
end

"""
$(TYPEDSIGNATURES)

Leftmost position `>= lo` whose value is at least `target`, or `0`.
"""
@inline function first_at_least(st::MaxTree{Tv}, lo::Int, target::Tv) where {Tv}
    lo > st.N && return 0
    tree = st.tree
    P = st.P
    i = lo + P - 1
    @inbounds tree[i] >= target && return lo
    @inbounds while true
        while isodd(i)                   # right child: climb until we are a left child
            i >>= 1
            i == 0 && return 0
        end
        i += 1                           # the right sibling covers the next positions
        if tree[i] >= target
            while i < P                  # descend to the leftmost qualifying leaf
                i <<= 1
                tree[i] < target && (i += 1)
            end
            j = i - P + 1
            return j <= st.N ? j : 0
        end
    end
end

workspace(::SegmentTreeSearch, s::QuantizedSeries) = MaxTree(s.values)

function waiting_times!(τ::AbstractVector{Tt}, s::QuantizedSeries{Tv, Tt}, δ::Threshold,
        alg::SegmentTreeSearch; workspace::Union{Nothing, MaxTree{Tv}} = nothing) where {
        Tv, Tt}
    q, t = s.values, s.times
    N = length(q)
    length(τ) == N || throw(DimensionMismatch("τ has length $(length(τ)), series has $N"))
    d = check_threshold(s, δ)
    st = workspace === nothing ? MaxTree(q) : workspace
    st.N == N || throw(DimensionMismatch("workspace was built for another series"))
    τ[N] = zero(Tt)
    tforeach(1:(N - 1); chunksize = alg.chunk_size) do i
        @inbounds begin
            j = first_at_least(st, i + 1, q[i] + d)
            τ[i] = j == 0 ? zero(Tt) : t[j] - t[i]
        end
    end
    return τ
end
