# Precompile workload: the paths a downstream tool or a pipeline script hits
# first, exercised on a synthetic series so that the first call after
# `using WaitingTimes` does not pay for compilation. Kept small and free of
# device backends; the pipeline path runs on a temporary directory that is
# removed afterwards.
using PrecompileTools: @compile_workload, @setup_workload

@setup_workload begin
    values = Union{Missing, Float64}[
        1.25, 3.5, missing, 2.0, 5.75, 4.0, 4.0, 6.25, 1.0, 3.0]
    @compile_workload begin
        s = QuantizedSeries(values, 2)
        δ = threshold(0.5, s)
        for alg in (NaiveSearch(), GuardedSearch(), SegmentTreeSearch(), FenwickSweep(),
            StreamingSearch(), DeviceSearch())
            τ = waiting_times(s, δ, alg)
            d = empirical_distribution(τ, δ, s)
            classify(τ, s)
            support(d), probabilities(d), cumulative(d), survival(d), nsamples(d)
            mean_waiting_time(d)
            scan_work(τ, s)
        end
        waiting_times(s, [δ, threshold(1.0, s)], FenwickSweep())
        parse_threshold(format_threshold(δ), 2)
        gap_table(s)
        est = OnlineWaitingTimes([0.5, 2.0], 2)
        for x in values
            ismissing(x) || push!(est, x)
        end
        snapshot(est)
        status(est)
        mktempdir() do dir
            csv = joinpath(dir, "series.csv")
            open(csv, "w") do io
                println(io, "value")
                for x in values
                    println(io, ismissing(x) ? "" : x)
                end
            end
            config = joinpath(dir, "run.toml")
            open(config, "w") do io
                print(io, """
                [input]
                path = "series.csv"
                format = "csv"
                value_column = "value"
                [quantization]
                digits = 2
                [thresholds]
                mode = "explicit"
                values = [0.5, 1.0]
                [algorithm]
                reference_checks = 1
                [output]
                root = "out"
                format = "csv"
                [run]
                log_level = "warn"
                """)
            end
            handle = run_pipeline(config)
            c = load_collection(handle.dir)
            distribution(c, "0.50")
            summary_table(c)
            list_collections(joinpath(dir, "out"))
        end
    end
end
