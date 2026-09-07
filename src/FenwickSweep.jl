# Fenwick sweep: one right-to-left pass over the series maintaining, for every
# distinct value, the smallest index seen so far; a prefix-minimum query over
# the value ranks answers each index in O(log V). Several thresholds are served
# in the same sweep.

"""
    FenwickSweep()

Second independent fast kernel. Sweeping the series from the end, a Fenwick
tree over the ranks of the distinct values holds the smallest index seen for
each value; the passage of index `n` is the minimum index among values at
least `q_n + d`, a prefix-minimum query in ``O(\\log V)``. The sweep is
sequential in `n` but serves any number of thresholds in one pass, so it is
the kernel of choice for dense threshold grids on machines with few cores and
for memory-constrained devices (the tree has `V` entries). Results equal
[`NaiveSearch`](@ref) bit for bit.
"""
struct FenwickSweep <: AbstractSearch end

"""
    FenwickWorkspace{Tv}

Sorted distinct values, the rank of every observation, and the tree buffer.

$(TYPEDFIELDS)
"""
struct FenwickWorkspace{Tv <: Integer}
    "sorted distinct values"
    unique_values::Vector{Tv}
    "rank of each observation in `unique_values`"
    rank::Vector{Int}
    "Fenwick tree of minimum index over reversed ranks"
    tree::Vector{Int}
end

function FenwickWorkspace(q::AbstractVector{Tv}) where {Tv <: Integer}
    unique_values = sort!(unique(q))
    rank = [searchsortedfirst(unique_values, v) for v in q]
    return FenwickWorkspace{Tv}(unique_values, rank, fill(typemax(Int), length(unique_values)))
end

workspace(::FenwickSweep, s::QuantizedSeries) = FenwickWorkspace(s.values)

"""
$(TYPEDSIGNATURES)

Waiting times for several thresholds in one sweep: `τs[k]` receives the
result for `δs[k]`. Each `τs[k]` must have length `N`.
"""
function waiting_times!(
        τs::AbstractVector{<:AbstractVector{Tt}}, s::QuantizedSeries{Tv, Tt},
        δs::AbstractVector{<:Threshold}, ::FenwickSweep;
        workspace::Union{Nothing, FenwickWorkspace{Tv}} = nothing) where {Tv, Tt}
    q, t = s.values, s.times
    N = length(q)
    length(τs) == length(δs) ||
        throw(DimensionMismatch("$(length(τs)) output vectors for $(length(δs)) thresholds"))
    for τ in τs
        length(τ) == N ||
            throw(DimensionMismatch("τ has length $(length(τ)), series has $N"))
    end
    ds = [check_threshold(s, δ) for δ in δs]
    ws = workspace === nothing ? FenwickWorkspace(q) : workspace
    length(ws.rank) == N ||
        throw(DimensionMismatch("workspace was built for another series"))
    uniq, rank, tree = ws.unique_values, ws.rank, ws.tree
    U = length(uniq)
    fill!(tree, typemax(Int))
    @inbounds for i in N:-1:1
        for k in eachindex(ds)
            r = searchsortedfirst(uniq, q[i] + ds[k])
            if r > U
                τs[k][i] = zero(Tt)
                continue
            end
            p = U - r + 1
            m = typemax(Int)
            while p > 0
                m = min(m, tree[p])
                p -= p & -p
            end
            τs[k][i] = m == typemax(Int) ? zero(Tt) : t[m] - t[i]
        end
        p = U - rank[i] + 1
        while p <= U
            tree[p] = min(tree[p], i)
            p += p & -p
        end
    end
    return τs
end

function waiting_times!(τ::AbstractVector{Tt}, s::QuantizedSeries{Tv, Tt}, δ::Threshold,
        alg::FenwickSweep; workspace::Union{Nothing, FenwickWorkspace{Tv}} = nothing) where {
        Tv, Tt}
    waiting_times!([τ], s, [δ], alg; workspace = workspace)
    return τ
end

"""
$(TYPEDSIGNATURES)

Allocating multi-threshold form: a vector of waiting-time vectors, one per
threshold, computed in a single sweep.
"""
function waiting_times(s::QuantizedSeries{Tv, Tt}, δs::AbstractVector{<:Threshold},
        alg::FenwickSweep; workspace = nothing) where {Tv, Tt}
    τs = [Vector{Tt}(undef, length(s)) for _ in δs]
    return waiting_times!(τs, s, δs, alg; workspace = workspace)
end
