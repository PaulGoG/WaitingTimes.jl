# Data gaps: detection, declaration with kinds, the structure of the record
# between them, and the post-hoc classification of waiting times. Gaps never
# change a waiting time; they qualify it.

"observed passage with no gap between the index and its passage"
const CLASS_EXACT = 0x01
"observed passage with at least one gap between the index and its passage"
const CLASS_GAP_CROSSING = 0x02
"no passage observed before the end of the record"
const CLASS_RIGHT_CENSORED = 0x03

"""
$(TYPEDSIGNATURES)

Gaps of a strictly increasing time vector under a cadence rule: every pair of
consecutive observations further apart than `cadence` encloses the gap
`[t_k + 1, t_{k+1})`. For a regular series `cadence = 1` marks every missing
sample; for irregular timestamps a larger `cadence` acts as a threshold.
"""
function detect_gaps(times::AbstractVector{Tt}, cadence::Integer) where {Tt <: Integer}
    cadence >= 1 || throw(ArgumentError("cadence must be at least 1, got $cadence"))
    gaps = Tuple{Tt, Tt}[]
    for k in 2:length(times)
        if times[k] - times[k - 1] > cadence
            push!(gaps, (times[k - 1] + one(Tt), times[k]))
        end
    end
    return gaps
end
detect_gaps(s::QuantizedSeries, cadence::Integer) = detect_gaps(s.times, cadence)

"one gap with its provenance while gap lists are merged"
const GapEntry{Tt} = NamedTuple{
    (:start, :stop, :kind, :source), Tuple{Tt, Tt, String, String}}

"precedence of the gap kinds when overlapping declarations are joined, most specific first"
const KIND_PRECEDENCE = reverse(GAP_KINDS)

function join_kinds(a::AbstractString, b::AbstractString)
    parts = unique!(String.(vcat(split(a, '+'), split(b, '+'))))
    length(parts) > 1 && filter!(!=("unknown"), parts)
    rank(p) = something(findfirst(==(p), KIND_PRECEDENCE), length(KIND_PRECEDENCE) + 1)
    return join(sort!(parts; by = rank), '+')
end

function join_sources(a::AbstractString, b::AbstractString)
    return join(unique!(filter!(!isempty, String.(vcat(split(a, ';'), split(b, ';'))))), ';')
end

"""
$(TYPEDSIGNATURES)

Merge gap entries into a sorted, disjoint list. Declared entries (every kind
but `"detected"`) that overlap, or touch with the same kind, are merged; when
their kinds differ the kinds are joined (`"session+hole"`), whereas touching
entries of different kinds stay separate gaps. A detected entry (a gap found
from the spacing of the time stamps) that overlaps declared gaps is absorbed
into them: the first extends to its start, the last to its stop, and the
space between consecutive ones inside it is given to the earlier. Detected
entries overlapping no declaration remain detected gaps.
"""
function merge_gaps(entries::AbstractVector{GapEntry{Tt}}) where {Tt}
    declared = sort!(filter(e -> e.kind != "detected", entries); by = e -> (
        e.start, e.stop))
    detected = sort!(filter(e -> e.kind == "detected", entries); by = e -> (
        e.start, e.stop))
    merged = GapEntry{Tt}[]
    for e in declared
        if !isempty(merged) &&
           (e.start < merged[end].stop ||
            (e.start == merged[end].stop && e.kind == merged[end].kind))
            g = merged[end]
            merged[end] = (start = g.start, stop = max(g.stop, e.stop),
                kind = g.kind == e.kind ? g.kind : join_kinds(g.kind, e.kind),
                source = join_sources(g.source, e.source))
        else
            push!(merged, e)
        end
    end
    spans = GapEntry{Tt}[]
    for e in detected
        if !isempty(spans) && e.start <= spans[end].stop
            g = spans[end]
            spans[end] = (start = g.start, stop = max(g.stop, e.stop), kind = g.kind,
                source = join_sources(g.source, e.source))
        else
            push!(spans, e)
        end
    end
    out = GapEntry{Tt}[]
    i = 1
    for d in spans
        while i <= length(merged) && merged[i].stop <= d.start
            push!(out, merged[i])
            i += 1
        end
        j = i
        while j <= length(merged) && merged[j].start < d.stop
            j += 1
        end
        if j == i
            push!(out, d)
            continue
        end
        for m in i:(j - 1)
            g = merged[m]
            start = m == i ? min(g.start, d.start) : g.start
            stop = m == j - 1 ? max(g.stop, d.stop) : merged[m + 1].start
            push!(out, (start = start, stop = stop, kind = g.kind, source = g.source))
        end
        i = j
    end
    append!(out, @view merged[i:end])
    return out
end

"entries of the gap list of `s`"
function gap_entries(s::QuantizedSeries{Tv, Tt}) where {Tv, Tt}
    return GapEntry{Tt}[(start = a, stop = b, kind = k, source = src)
                        for ((a, b), k, src) in zip(s.gaps, s.gap_kinds, s.gap_sources)]
end

"""
$(TYPEDSIGNATURES)

Copy of the series with `intervals` `[start, stop)` merged into its gap list
(declared gaps from schedules, session boundaries, producer gap tables or
quality logs). `intervals` holds `(start, stop)` pairs, which take `kind` and
`source`, or named tuples `(start, stop, kind, source)`. Kinds are those of
[`GAP_KINDS`](@ref) other than `"detected"`; overlapping intervals are merged
as described in [`merge_gaps`](@ref). An interval containing an observation or
reaching outside the record is rejected. The series' record gains a
`declare_gaps` step; the argument is unchanged.
"""
function declare_gaps(s::QuantizedSeries{Tv, Tt}, intervals::AbstractVector;
        kind::AbstractString = "declared", source::AbstractString = "") where {Tv, Tt}
    new = GapEntry{Tt}[]
    for iv in intervals
        entry = iv isa NamedTuple ?
                (start = Tt(iv.start), stop = Tt(iv.stop),
            kind = String(get(iv, :kind, kind)), source = String(get(iv, :source, source))) :
                (start = Tt(iv[1]), stop = Tt(iv[2]),
            kind = String(kind), source = String(source))
        check_gap_kind(entry.kind)
        entry.kind == "detected" &&
            throw(ArgumentError("declared gaps cannot have the kind \"detected\""))
        entry.start < entry.stop ||
            throw(ArgumentError("declared gap [$(entry.start), $(entry.stop)) is empty"))
        push!(new, entry)
    end
    out = merge_gaps(vcat(gap_entries(s), new))
    kinds = sort!(unique(e.kind for e in new))
    record = with_step(s.record, :declare_gaps,
        Dict{String, Any}("n_intervals" => length(intervals), "kinds" => kinds),
        Dict{String, Any}("n_gaps" => length(out)))
    return QuantizedSeries(
        s.values, s.times, s.digits; gaps = [(e.start, e.stop) for e in out],
        gap_kinds = [e.kind for e in out], gap_sources = [e.source for e in out],
        time_unit = s.time_unit, epoch = s.epoch, record = record)
end

"""
$(TYPEDSIGNATURES)

Gaps of the series as named tuples `(start, stop, length, kind, source)`,
longest first.
"""
function gap_table(s::QuantizedSeries)
    rows = [(start = a, stop = b, length = b - a, kind = k, source = src)
            for ((a, b), k, src) in zip(s.gaps, s.gap_kinds, s.gap_sources)]
    return sort!(rows; by = r -> r.length, rev = true)
end

# --- record structure ----------------------------------------------------------

"""
$(TYPEDSIGNATURES)

Sampling step of the time axis: the greatest common divisor of the
differences between consecutive observation times (1 for a single
observation). On a regular grid with gaps it is the cadence of the grid.
"""
function sampling_step(s::QuantizedSeries{Tv, Tt}) where {Tv, Tt}
    length(s) == 1 && return one(Tt)
    step = zero(Tt)
    @inbounds for n in 2:length(s)
        step = gcd(step, s.times[n] - s.times[n - 1])
        step == 1 && break
    end
    return step
end

"""
$(TYPEDSIGNATURES)

Number of positions of the sampling grid from the first to the last
observation, ``N = (t_N - t_1)/\\Delta + 1`` with ``\\Delta`` the
[`sampling_step`](@ref); on a unit-cadence axis ``N = t_N - t_1 + 1``, the
elapsed length of the record.
"""
function record_length(s::QuantizedSeries)
    Int((last(s.times) - first(s.times)) ÷ sampling_step(s)) + 1
end

"""
$(TYPEDSIGNATURES)

Observed positions of the sampling grid: a `BitVector` of length
[`record_length`](@ref) that is `true` where an observation lies. Records
longer than `max_length` positions (an irregular or finely resolved time
axis) are refused.
"""
function observed_mask(s::QuantizedSeries; max_length::Integer = 10^9)
    N = record_length(s)
    N <= max_length || throw(ArgumentError(
        "the record spans $N grid positions (sampling step $(sampling_step(s))), more than max_length = $max_length",
    ))
    Δ = sampling_step(s)
    mask = falses(N)
    t1 = first(s.times)
    @inbounds for t in s.times
        mask[Int((t - t1) ÷ Δ) + 1] = true
    end
    return mask
end

"""
$(TYPEDSIGNATURES)

Maximal runs of observations not separated by a gap of any kind, as named
tuples `(first, last, kind_before, kind_after)`: indices of the first and last
observation of the run, and the kinds of the gaps that bound it (empty at the
ends of the record).
"""
function segment_runs(s::QuantizedSeries)
    runs = NamedTuple{(:first, :last, :kind_before, :kind_after),
        Tuple{Int, Int, String, String}}[]
    times, gaps = s.times, s.gaps
    g = 1
    first_index = 1
    kind_before = ""
    for n in 1:(length(s) - 1)
        while g <= length(gaps) && gaps[g][1] <= times[n]
            g += 1
        end
        (g <= length(gaps) && gaps[g][1] < times[n + 1]) || continue
        h = g
        while h < length(gaps) && gaps[h + 1][1] < times[n + 1]
            h += 1
        end
        push!(runs, (first = first_index, last = n, kind_before = kind_before,
            kind_after = s.gap_kinds[g]))
        first_index = n + 1
        kind_before = s.gap_kinds[h]
        g = h + 1
    end
    push!(runs, (first = first_index, last = length(s), kind_before = kind_before,
        kind_after = ""))
    return runs
end

"""
$(TYPEDSIGNATURES)

Lengths, in observations, of the maximal runs of observations not separated
by a gap of any kind, in record order; they sum to `length(s)`. The erosion
weight of a lag of `k` observations is ``w(k) = \\sum_s (L_s - k)_+``.
"""
segment_lengths(s::QuantizedSeries) = [r.last - r.first + 1 for r in segment_runs(s)]

"""
$(TYPEDSIGNATURES)

The segments of the series as named tuples `(start, stop, length, kind_before,
kind_after)`: `[start, stop)` from the first observation of the run to one
time unit after its last, the number of observations, and the kinds of the
bounding gaps (empty at the ends of the record).
"""
function segment_table(s::QuantizedSeries)
    return [(start = s.times[r.first], stop = s.times[r.last] + 1,
                length = r.last - r.first + 1, kind_before = r.kind_before,
                kind_after = r.kind_after) for r in segment_runs(s)]
end

"""
$(TYPEDSIGNATURES)

Classify the waiting times `τ` of `s` (sentinel `0` for no observed passage)
against its gap list. Returns `(class, lower, upper)` with `class` one of
`CLASS_EXACT`, `CLASS_GAP_CROSSING`, `CLASS_RIGHT_CENSORED` and the bounds on
the true waiting time: for an exact wait both equal `τ[n]`; for a gap-crossing
wait the lower bound is the elapsed time to the last observation before the
first gap and the upper bound is `τ[n]`; for a right-censored index the lower
bound is the elapsed time to the last observation before the first gap (or to
the end of the record) and the upper bound is `typemax`. Index `N` is never a
candidate and is reported as right-censored with both bounds zero.
"""
function classify(τ::AbstractVector{Tt}, s::QuantizedSeries{Tv, Tt}) where {Tv, Tt}
    N = length(s)
    length(τ) == N || throw(DimensionMismatch("τ has length $(length(τ)), series has $N"))
    times, gaps = s.times, s.gaps
    starts = first.(gaps)
    class = Vector{UInt8}(undef, N)
    lower = Vector{Tt}(undef, N)
    upper = Vector{Tt}(undef, N)
    @inbounds for n in 1:(N - 1)
        t_n = times[n]
        g = searchsortedfirst(starts, t_n + one(Tt))   # first gap starting after t_n
        has_gap = g <= length(starts)
        if τ[n] == 0
            class[n] = CLASS_RIGHT_CENSORED
            lower[n] = has_gap ? last_observation_before(times, starts[g]) - t_n :
                       times[N] - t_n
            upper[n] = typemax(Tt)
        elseif has_gap && starts[g] < t_n + τ[n]
            class[n] = CLASS_GAP_CROSSING
            lower[n] = last_observation_before(times, starts[g]) - t_n
            upper[n] = τ[n]
        else
            class[n] = CLASS_EXACT
            lower[n] = τ[n]
            upper[n] = τ[n]
        end
    end
    class[N] = CLASS_RIGHT_CENSORED
    lower[N] = zero(Tt)
    upper[N] = zero(Tt)
    return class, lower, upper
end

"time of the last observation strictly before `t`"
function last_observation_before(times::AbstractVector{Tt}, t::Tt) where {Tt}
    i = searchsortedfirst(times, t) - 1
    return times[max(i, 1)]
end

"""
$(TYPEDSIGNATURES)

Counts of the classes over the candidate indices `1:N-1`, as the named tuple
`(n_candidates, n_exact, n_gap_crossing, n_right_censored)`.
"""
function class_counts(class::AbstractVector{UInt8})
    N = length(class)
    n_exact = n_gap = n_cens = 0
    @inbounds for n in 1:(N - 1)
        c = class[n]
        n_exact += c == CLASS_EXACT
        n_gap += c == CLASS_GAP_CROSSING
        n_cens += c == CLASS_RIGHT_CENSORED
    end
    return (n_candidates = N - 1, n_exact = n_exact, n_gap_crossing = n_gap,
        n_right_censored = n_cens)
end
