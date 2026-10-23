# Worked consumer and collection contract for MarketTickStreamer.jl: the
# waiting-time distributions of a tick stream, live and batch, and the
# collection that names its source session.
#
#   julia --threads=auto examples/tick_stream.jl [RAW_SESSION.jsonl ...]
#   julia --threads=auto examples/tick_stream.jl --follow RAW_DIR [SESSION]
#
# The consumer takes a `Channel{Trade}` of MarketTickStreamer.jl and never
# learns whether the ticks came from the wire (`live_source`), from a
# recording (`replay_source`), from the raw files of a session another
# process is writing (`follow_source`) or, as here without a recording,
# from a synthetic tape. It feeds an `OnlineWaitingTimes` estimator for a
# grid of price thresholds under the producer's snapshot convention
# (`snapshots`: the estimator's state at every multiple of a period on the
# exchange clock and once at close, a function of the sequence alone), then
# checks the online distributions against the batch pipeline on the same
# ticks: the prints in the schema of the producer's processed files
# (`trades_table`) are read back with `read_series(format = :tick)`, and the
# batch result of `StreamingSearch` must equal the online snapshot exactly.
#
# The synthetic tape is laid on the calendar MarketTickStreamer gives a US
# equity venue (`provider_spec(Val(:alpaca))`: America/New_York, regular
# session 9:30 to 16:00, Monday to Friday), so its sessions are separated by
# exchange closures. The second part takes the tape through the producer's
# own persistence: the raw NDJSON sink, the session sidecar
# (`write_session_meta`), compaction into the processed tree (`compact_raw`,
# one file per symbol and trading day) and the corpus read
# (`read_processed`), and follows the finished session through its files
# (`follow_source`). It declares the closures as gaps of kind "session" and
# generates one collection on the elapsed axis (exchange time in
# nanoseconds) and one on the index axis (trade count), then asserts the
# collection contract (provenance schema 3, source summary, gap kinds,
# record structure, per-class partitions), so that a change of the producer
# that breaks it fails here. With raw session files as arguments the ticks
# come from `replay_source(files; pace = "max")`, with `--follow` from
# `follow_source(dir; session)`, and only the online check runs.
include(joinpath(@__DIR__, "activate.jl"))

using CSV: CSV
using DataFrames: DataFrame, nrow
using Dates: Date, DateTime, Day, dayofweek, datetime2unix, unix2datetime
using MarketTickStreamer: MarketTickStreamer, Trade, compact_raw, follow_source,
                          load_config, price_forming, provider_spec, read_processed,
                          replay_source, snapshots, tee, trades_table, trading_date
using Printf: @printf
using StableRNGs: StableRNG
using TOML: TOML
using WaitingTimes
using WaitingTimes.Preprocessing: read_series, quantized_series
using WaitingTimes.Synthetic: random_walk

const DIGITS = 2                                   # prices in cents
const DELTAS = [0.01, 0.05, 0.25, 1.0]             # price thresholds
const SYMBOL = "SYN"
const FIRST_SESSION = Date(2026, 4, 6)             # a Monday; New York on EDT (UTC-4)
const UTC_OFFSET_HOURS = 4
const SNAPSHOT_PERIOD_NS = 3_600 * 10^9            # one hour of exchange time

"one snapshot of the estimator: the boundary on the exchange clock, the prints folded, the waits resolved per threshold"
const Snapshot = @NamedTuple{at::Int64, n::Int, final::Bool, resolved::Vector{Int}}

"nanoseconds since the UNIX epoch of a New York local time on EDT"
function local_ns(d::Date, hours::Real)
    round(Int64,
        (datetime2unix(DateTime(d)) + (hours + UTC_OFFSET_HOURS) * 3600) * 1e9)
end

"""
    session_calendar(n_sessions) -> Vector{Tuple{Int64,Int64}}

Open and close instants (ns) of the first `n_sessions` regular sessions from
`FIRST_SESSION`, Monday to Friday, on the session hours of MarketTickStreamer's
US equity provider.
"""
function session_calendar(n_sessions::Integer)
    open_h, close_h = provider_spec(Val(:alpaca)).regular_session
    days = Date[]
    d = FIRST_SESSION
    while length(days) < n_sessions
        dayofweek(d) <= 5 && push!(days, d)
        d += Day(1)
    end
    return [(local_ns(day, open_h), local_ns(day, close_h)) for day in days]
end

"""
    synthetic_tape(n; seed) -> (Channel{Trade}, sessions)

A channel of `n` synthetic prints: a random walk with cent-level increments
at exponentially spaced exchange times, 0.25 s apart on average, laid on the
regular sessions of the calendar; returns the channel and the sessions used.
"""
function synthetic_tape(n::Integer; seed::Integer = 2026)
    rng = StableRNG(seed)
    prices = round.(100 .+ 0.02 .* random_walk(rng, n); digits = DIGITS)
    clock = cumsum(round.(Int64, -log.(rand(rng, n)) .* 250_000_000) .+ 1)   # trading time [ns]
    length_ns = let (o, c) = only(session_calendar(1))
        c - o
    end
    n_sessions = Int(fld(last(clock), length_ns)) + 1
    sessions = session_calendar(n_sessions)
    times = [first(sessions[fld(τ, length_ns) + 1]) + mod(τ, length_ns) for τ in clock]
    ch = Channel{Trade}(10_000)
    Threads.@spawn begin
        for (k, (t, p)) in enumerate(zip(times, prices))
            put!(ch, Trade(SYMBOL, t, t + 1_000, p, 100.0, "X", String[], "A", k))
        end
        close(ch)
    end
    return ch, sessions
end

"""
    consume(ch) -> (estimator, trades, persisted, snapshots)

Drain the channel through a lossless analysis tap into the online estimator
under the producer's snapshot convention, keeping every price-forming print,
and return the ticks seen for the batch check and the snapshot rows: the
boundary on the exchange clock, the prints folded so far and the waits
resolved per threshold. The persistence tap only counts.
"""
function consume(ch::Channel{Trade})
    persist, analyse = tee(ch, 2; capacity = 10_000, lossy = [false, false])
    counted = Ref(0)
    counter = Threads.@spawn for _ in persist
        counted[] += 1
    end
    est = OnlineWaitingTimes(DELTAS, DIGITS; time_unit = :nanosecond, late_policy = :skip)
    trades = Trade[]
    rows = Snapshot[]
    on_snapshot(at, n, final) = push!(rows,
        (at = at, n = n, final = final, resolved = [r.resolved for r in status(est)]))
    snapshots(analyse, SNAPSHOT_PERIOD_NS; on_snapshot) do trade
        price_forming(trade) || return
        push!(est, trade.time_ns, trade.price)
        push!(trades, trade)
    end
    wait(counter)
    return est, trades, counted[], rows
end

"assert one clause of the collection contract, naming it when it fails"
function contract(ok::Bool, clause::AbstractString)
    ok || error("collection contract broken: $clause")
end

# --- the source: a synthetic tape, a replayed recording or a followed session ------
follow_at = findfirst(==("--follow"), ARGS)
synthetic = isempty(ARGS)
source, sessions = if follow_at !== nothing
    length(ARGS) > follow_at || error("--follow needs the raw directory of the session")
    session = length(ARGS) > follow_at + 1 ? ARGS[follow_at + 2] : nothing
    follow_source(ARGS[follow_at + 1]; session), nothing
elseif synthetic
    synthetic_tape(200_000)
else
    replay_source(ARGS; pace = "max"), nothing
end
est, trades, persisted, snaps = consume(source)
isempty(trades) && error("the source delivered no price-forming print")
println(est)
println("prints persisted ", persisted, ", price-forming ",
    length(trades), ", late ", est.n_late)
for row in status(est)
    @printf("  δ = %-6s resolved %8d  pending %6d  mean wait %10.3e ns\n",
        row.delta, row.resolved, row.pending, row.mean_waiting_time)
end
quiet = count(k -> k > 1 && snaps[k].n == snaps[k - 1].n, eachindex(snaps))
@printf("  %d hourly snapshots on the exchange clock, %d without new prints; final at %s after %d prints, resolved %s\n",
    length(snaps), quiet, unix2datetime(last(snaps).at / 1e9),
    last(snaps).n,
    join(last(snaps).resolved, " "))

# --- batch check on the same ticks -------------------------------------------
mktempdir() do dir
    path = joinpath(dir, SYMBOL * ".csv")
    CSV.write(path, trades_table(trades))                # the schema of the processed files
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

# --- collections that name their source session --------------------------------
synthetic || exit()
mktempdir() do dir
    # the producer's shipped configuration (a read-only template in an installed
    # copy), with its data tree in the temporary directory
    mts_config = TOML.parsefile(MarketTickStreamer.DEFAULT_CONFIG)
    mts_config["storage"]["data_dir"] = joinpath(dir, "mts")
    mts_config["stream"]["symbols"] = [SYMBOL]
    open(io -> TOML.print(io, mts_config), joinpath(dir, "mts.toml"), "w")
    cfg = load_config(joinpath(dir, "mts.toml"))

    # the session as the producer persists it: raw parts, the sidecar, the
    # processed day files; then the two ways a consumer reads it back
    sid = MarketTickStreamer.session_id(cfg)
    sink = MarketTickStreamer.open_raw_sink(cfg.raw_dir, sid)
    MarketTickStreamer.write_batch!(sink, trades)
    MarketTickStreamer.close_sink!(sink)
    sidecar = MarketTickStreamer.write_session_meta(cfg, sid; status = "completed",
        ticks = length(trades), raw_files = [sink.path],
        started_utc = unix2datetime(first(trades).time_ns / 1e9),
        finished_utc = unix2datetime(last(trades).time_ns / 1e9))
    days = compact_raw([sink.path], cfg.processed_dir;
        format = cfg.processed_format, tz = cfg.exchange_tz)
    corpus = read_processed(cfg, SYMBOL)
    followed = collect(follow_source(cfg.raw_dir; session = sid))
    contract(
        length(days) == length(sessions) &&
            Set(Date(first(splitext(basename(f)))) for f in days) ==
            Set(trading_date(t.time_ns; tz = cfg.exchange_tz) for t in trades),
        "one processed day file per session of the calendar")
    contract(corpus == trades, "the corpus read returns the persisted prints in exchange-time order")
    contract(followed == trades, "the finished session is followed whole through its files")
    tick_file = joinpath(dir, SYMBOL * ".csv")
    CSV.write(tick_file, trades_table(corpus))

    closures = [(start = sessions[k][2], stop = sessions[k + 1][1], kind = "session",
                    source = "provider_spec(alpaca).regular_session")
                for k in 1:(length(sessions) - 1)]
    open(joinpath(dir, "closures.toml"), "w") do io
        TOML.print(io,
            Dict("gaps" => [Dict("start" => c.start, "stop" => c.stop,
                 "kind" => c.kind, "source" => c.source) for c in closures]))
    end
    collections = Dict{String, Any}()
    for axis in ("elapsed", "index")
        config = joinpath(dir, "ticks_$(axis).toml")
        open(config, "w") do io
            TOML.print(io,
                Dict(
                    "input" => Dict("path" => tick_file, "format" => "tick",
                        "value_column" => "price",
                        "time_column" => "time_ns", "epoch_unit" => "nanosecond",
                        "time_unit" => "nanosecond", "tie_policy" => "last", "time_axis" =>
                            axis,
                        "source_descriptor" => sidecar),
                    "gaps" => Dict("declared" => joinpath(dir, "closures.toml"),
                        "detect" => "threshold", "threshold" => 60_000_000_000),
                    "quantization" => Dict("digits" => DIGITS),
                    "thresholds" => Dict("mode" => "explicit", "values" => DELTAS),
                    "output" =>
                        Dict("root" => joinpath(dir, "collections"), "format" => "csv")))
        end
        collections[axis] = load_collection(run_pipeline(config).dir)
    end
    ce, ci = collections["elapsed"], collections["index"]
    show(stdout, MIME("text/plain"), ce)
    println()

    # the collection contract
    for c in (ce, ci)
        contract(c.metadata["schema"] == "waitingtimes-provenance/3", "schema 3")
        summary = WaitingTimes.source_summary(c)
        contract(summary !== nothing && summary.producer == "MarketTickStreamer",
            "source summary names MarketTickStreamer")
        contract(summary.compat_satisfied, "producer version admitted")
        descriptor = source_descriptor(c)
        contract(
            descriptor["session"]["id"] == sid &&
                descriptor["session"]["status"] == "completed",
            "sidecar copied verbatim")
        contract(descriptor["provenance"]["timestamp_unit"] == "nanosecond",
            "the sidecar records the venue's timestamp unit")
        contract(
            all(haskey(c.metadata["producer"], k)
            for k in ("name", "version", "git_tree_sha1", "git_dirty", "git_commit")),
            "[producer] identity")
        contract(isfile(joinpath(c.dir, c.metadata["environment"]["manifest_file"])),
            "manifest snapshot")
        contract(sum(WaitingTimes.segment_lengths(c)) == c.n_observations, "segments cover the series")
        for δ in DELTAS
            d = distribution(c, δ)
            cc = WaitingTimes.class_counts(c, δ)
            ch = WaitingTimes.censoring_histogram(c, δ)
            contract(cc.exact .+ cc.gap_crossing == WaitingTimes.counts(d), "per-class counts")
            contract(sum(ch.count) == d.n_right_censored, "censoring histogram")
        end
    end
    gaps_e = CSV.read(joinpath(ce.dir, "gaps.csv"), DataFrame)
    contract(nrow(gaps_e) == length(closures) && all(==("session"), gaps_e.kind),
        "closures are the session gaps of the elapsed axis")
    contract(ci.time_axis === :index && ci.n_gaps == 0, "closures close on the index axis")
    original = CSV.read(joinpath(ci.dir, "gaps_original.csv"), DataFrame)
    contract(original.kind == gaps_e.kind && original.start == gaps_e.start,
        "the original clock keeps the session gaps")
    contract(WaitingTimes.record_length(ci) == ci.n_observations, "trade count is the index")
    summary = WaitingTimes.source_summary(ce)
    println("source: ", summary.producer, " ", summary.producer_version, ", session ",
        source_descriptor(ce)["session"]["id"], ", code identity ",
        summary.identity ? summary.git_tree_sha1 : "not recorded by the producer")
    for (name, c) in (("elapsed [ns]", ce), ("index [trades]", ci))
        d = distribution(c, 1.0)
        @printf("  %-15s δ = 1.00: %7d waits, longest %.4g, gap-crossing %d, censored %d\n",
            name, WaitingTimes.nsamples(d), last(WaitingTimes.support(d)),
            d.n_gap_crossing,
            d.n_right_censored)
    end
    println("collection contract holds on both axes")
end
