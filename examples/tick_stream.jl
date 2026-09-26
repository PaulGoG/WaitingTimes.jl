# Worked consumer: waiting-time distributions of a tick stream, live and batch.
#
#   julia --threads=auto examples/tick_stream.jl [RAW_SESSION.jsonl ...]
#
# The consumer takes a `Channel{Trade}` of MarketTickStreamer.jl and never
# learns whether the ticks came from the wire, from a recording or, as here
# without a recording, from a synthetic tape. It feeds an
# `OnlineWaitingTimes` estimator for a grid of price thresholds, then checks
# the online distributions against the batch pipeline on the same ticks: the
# compacted per-symbol file that MarketTickStreamer writes is read back with
# `read_series(format = :tick)`, and the batch result of `StreamingSearch`
# must equal the online snapshot exactly.
#
# With raw session files as arguments the ticks come from
# `replay_source(files; pace = "max")` instead of the synthetic tape.
include(joinpath(@__DIR__, "activate.jl"))

using CSV: CSV
using DataFrames: DataFrame
using MarketTickStreamer: Trade, price_forming, replay_source, tee
using Printf: @printf
using StableRNGs: StableRNG
using WaitingTimes
using WaitingTimes.Preprocessing: read_series, quantized_series
using WaitingTimes.Synthetic: irregular_times, random_walk

const DIGITS = 2                                   # prices in cents
const DELTAS = [0.01, 0.05, 0.25, 1.0]             # price thresholds
const SYMBOL = "SYN"

"""
    synthetic_tape(n; seed) -> Channel{Trade}

A channel of `n` synthetic prints: a random walk with cent-level increments
on exponentially spaced exchange times, in the shape of a replayed session.
"""
function synthetic_tape(n::Integer; seed::Integer = 2026)
    rng = StableRNG(seed)
    prices = round.(100 .+ 0.02 .* random_walk(rng, n); digits = DIGITS)
    times = irregular_times(rng, n; mean_interval = 250_000_000, origin = 1_700_000_000_000_000_000)
    ch = Channel{Trade}(10_000)
    Threads.@spawn begin
        for (k, (t, p)) in enumerate(zip(times, prices))
            put!(ch, Trade(SYMBOL, t, t + 1_000, p, 100.0, "X", String[], "A", k))
        end
        close(ch)
    end
    return ch
end

"""
    consume(ch) -> (estimator, trades)

Drain the channel through a lossless analysis tap into the online estimator,
keeping every price-forming print, and return the ticks seen for the batch
check. The persistence tap only counts.
"""
function consume(ch::Channel{Trade})
    persist, analyse = tee(ch, 2; capacity = 10_000, lossy = [false, false])
    counted = Ref(0)
    counter = Threads.@spawn for _ in persist
        counted[] += 1
    end
    est = OnlineWaitingTimes(DELTAS, DIGITS; time_unit = :nanosecond, late_policy = :skip)
    trades = Trade[]
    for trade in analyse
        price_forming(trade) || continue
        push!(est, trade.time_ns, trade.price)
        push!(trades, trade)
    end
    wait(counter)
    return est, trades, counted[]
end

source = isempty(ARGS) ? synthetic_tape(200_000) : replay_source(ARGS; pace = "max")
est, trades, persisted = consume(source)
println(est)
println("prints persisted ", persisted, ", price-forming ", length(trades), ", late ", est.n_late)
for row in status(est)
    @printf("  δ = %-6s resolved %8d  pending %6d  mean wait %10.3e ns\n",
        row.delta, row.resolved, row.pending, row.mean_waiting_time)
end

# --- batch check on the same ticks -------------------------------------------
# The compacted file MarketTickStreamer writes has these columns; the tick
# reader of WaitingTimes takes `time_ns` and `price` from it.
mktempdir() do dir
    path = joinpath(dir, SYMBOL * ".csv")
    CSV.write(path, DataFrame(symbol = [t.symbol for t in trades],
        time_ns = [t.time_ns for t in trades], recv_ns = [t.recv_ns for t in trades],
        price = [t.price for t in trades], size = [t.size for t in trades],
        exchange = [t.exchange for t in trades], conditions = [join(t.conditions, "|") for t in trades],
        tape = [t.tape for t in trades], id = [t.id for t in trades]))
    rs = read_series(path; format = :tick, value_column = "price", tie_policy = :last)
    s = quantized_series(rs, DIGITS; detect = :none)
    online = snapshot(est)
    agree = true
    for (δ, d_online) in zip(DELTAS, online)
        thr = threshold(δ, s)
        d_batch = empirical_distribution(waiting_times(s, thr, StreamingSearch()), thr, s)
        same = WaitingTimes.support(d_online) == WaitingTimes.support(d_batch) &&
               WaitingTimes.counts(d_online) == WaitingTimes.counts(d_batch)
        agree &= same
        @printf("  δ = %-6s online %8d waits, batch %8d waits, equal %s\n",
            format_threshold(thr), WaitingTimes.nsamples(d_online),
            WaitingTimes.nsamples(d_batch), same)
    end
    agree || error("online and batch distributions differ")
    println("online estimator equals the batch pipeline on every threshold")
end
