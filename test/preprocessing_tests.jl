@testset "Preprocessing operations: slug tags, defaults, grid arithmetic" begin
    D(pairs...) = Dict{String, Any}(pairs...)

    # slug tags, absent optional keys taking the operation's defaults
    tags = [
        "trailing30" => D("op" => "trailing_mean_fluctuations", "window" => 30),
        "trailing30scaled" => D("op" => "trailing_mean_fluctuations", "window" => 30,
            "denominator" => "scale"),
        "trailing30abs" => D("op" => "trailing_mean_fluctuations", "window" => 30,
            "denominator" => "none"),
        "round2" => D("op" => "round", "digits" => 2),
        "detrend5" => D("op" => "detrend_moving_average", "window" => 5),
        "clip0.01" => D("op" => "clip_quantile", "q" => 0.01),
        "sigma3" => D("op" => "clip_sigma"),
        "sigma2.5" => D("op" => "clip_sigma", "k" => 2.5),
        "prune0.004" => D("op" => "clip_extremes", "digits" => 2),
        "logret" => D("op" => "log_returns"),
        "loglevels" => D("op" => "log_levels"),
        "diff" => D("op" => "differences"),
        "range" => D("op" => "select_range", "from" => 1),
        "cut" => D("op" => "exclude_intervals", "intervals" => [[1, 2]]),
        "ties" => D("op" => "collapse_ties", "policy" => "first")
    ]
    for (expected, step) in tags
        @test WT.Config.step_tag(step) == expected
    end

    # a step with its required keys only gives the series of the direct call:
    # the defaults of PREPROCESSING_OPS equal the keyword defaults of the transforms
    P = WT.Preprocessing
    rng = StableRNG(11)
    values = Vector{Union{Missing, Float64}}(
        round.(100 .+ 0.1 .* cumsum(randn(rng, 300)); digits = 2))
    values[7] = missing
    rs = P.RawSeries(values, collect(Int64, 1:300), :sample, nothing,
        PreparationRecord("defaults"))
    tied = P.RawSeries(values, [1; 1; 2:299], :sample, nothing, PreparationRecord("ties"))
    same(a, b) = isequal(a.values, b.values) && isequal(a.times, b.times)
    cases = [
        (rs, D("op" => "select_range", "from" => 10, "to" => 250),
            P.select_range(rs; from = 10, to = 250)),
        (rs, D("op" => "exclude_intervals", "intervals" => [[20, 30]]),
            P.exclude_intervals(rs, [(20, 30)])),
        (rs, D("op" => "round", "digits" => 1), P.round_values(rs; digits = 1)),
        (rs, D("op" => "trailing_mean_fluctuations", "window" => 24),
            P.trailing_mean_fluctuations(rs; window = 24)),
        (rs, D("op" => "log_returns"), P.log_returns(rs)),
        (rs, D("op" => "log_levels"), P.log_levels(rs)),
        (rs, D("op" => "differences"), P.differences(rs)),
        (rs, D("op" => "detrend_moving_average", "window" => 5),
            P.detrend_moving_average(rs; window = 5)),
        (rs, D("op" => "clip_quantile", "q" => 0.02), P.clip_quantile(rs; q = 0.02)),
        (rs, D("op" => "clip_extremes", "digits" => 2), P.clip_extremes(rs; digits = 2)),
        (rs, D("op" => "clip_sigma"), P.clip_sigma(rs)),
        (tied, D("op" => "collapse_ties", "policy" => "first"),
            P.collapse_ties(tied, :first))
    ]
    @test Set(c[2]["op"] for c in cases) == Set(keys(WT.Config.PREPROCESSING_OPS)) ==
          Set(keys(P.STEP_TRANSFORMS))
    for (series, step, direct) in cases
        @test same(P.apply_steps(series, [step]), direct)
    end

    # grid arithmetic
    @test WT.on_grid(0.25, 2) && !WT.on_grid(0.255, 2)
    @test WT.quantize(0.25, 2) == 25

    # keys ignored under the active mode, and removed keys
    mktempdir() do dir
        write(joinpath(dir, "series.csv"), "value\n1.00\n1.25\n1.10\n1.40\n")
        linear = "[thresholds]\nmode = \"linear\"\nmin = 0.05\nmax = 0.25\nstep = 0.05\n"
        function config(rest; input = "")
            path = joinpath(dir, "c.toml")
            write(path,
                "[input]\npath = \"series.csv\"\nvalue_column = \"value\"\n$input" *
                "[quantization]\ndigits = 2\n" * rest)
            return path
        end
        @test_logs (:warn, r"chunk_size") match_mode = :any load_settings(config(
            linear * "[algorithm]\nsearch = \"fenwick_sweep\"\nchunk_size = 8\n"))
        @test_logs (:warn, r"backend") match_mode = :any load_settings(config(
            linear * "[algorithm]\nbackend = \"cuda\"\n"))
        @test_logs (:warn, r"cadence") match_mode = :any load_settings(config(
            linear * "[gaps]\ndetect = \"none\"\ncadence = 1\n"))
        @test_logs (:warn, r"step") match_mode = :any load_settings(config(
            "[thresholds]\nmode = \"explicit\"\nvalues = [0.05, 0.1]\nstep = 0.05\n"))
        settings = @test_logs (:warn, r"unknown configuration key") match_mode = :any load_settings(config(
            linear; input = "quantity_label = \"level\"\n"))
        @test settings isa WT.Settings
    end
end

@testset "Configuration values rejected on load" begin
    mktempdir() do dir
        write(joinpath(dir, "series.csv"), "value\n1.00\n1.25\n1.10\n1.40\n")
        function config(rest; input = "")
            path = joinpath(dir, "c.toml")
            write(path,
                "[input]\npath = \"series.csv\"\nvalue_column = \"value\"\n$input" *
                "[quantization]\ndigits = 2\n" *
                "[thresholds]\nmode = \"linear\"\nmin = 0.05\nmax = 0.25\nstep = 0.05\n" *
                rest)
            return path
        end
        message(path) =
            try
                load_settings(path)
                ""
            catch e
                e isa ArgumentError ? e.msg : rethrow()
            end
        step(body) = "[[preprocessing.steps]]\n" * body
        @test load_settings(config("")) isa WT.Settings
        # a choice that is not a string names its key
        @test occursin("[gaps] detect", message(config("[gaps]\ndetect = false\n")))
        @test occursin("[algorithm] backend", message(config("[algorithm]\nbackend = 1\n")))
        # the choices of the sections are case-insensitive
        @test load_settings(config("[gaps]\ndetect = \"None\"\n")).gap_detect === :none
        # step parameters are used as written
        @test occursin("denominator",
            message(config(step("op = \"trailing_mean_fluctuations\"\nwindow = 2\n" *
                                "denominator = \"Mean\"\n"))))
        @test occursin("policy",
            message(config(step("op = \"collapse_ties\"\npolicy = \"First\"\n"))))
        @test length(load_settings(config(step(
            "op = \"trailing_mean_fluctuations\"\nwindow = 2\n" *
            "denominator = \"mean\"\n"))).steps) == 1
        # a delimiter is one character
        @test occursin("[input] delimiter",
            message(config(""; input = "delimiter = '\\t'\n")))
        @test load_settings(config(""; input = "delimiter = \";\"\n")).delimiter == ";"
        # interval pairs are integers with start < stop, and do not overlap
        for bad in ("[[20, 10]]", "[[10.5, 20]]", "[[1, 2, 3]]", "[[true, 2]]",
            "[[0, 1e19]]", "[[5, 20], [1, 10]]")
            @test occursin("intervals",
                message(config(step("op = \"exclude_intervals\"\nintervals = $bad\n"))))
        end
        @test length(load_settings(config(step(
            "op = \"exclude_intervals\"\nintervals = [[1, 2], [3.0, 4]]\n"))).steps) == 1
        @test length(load_settings(config(step(
            "op = \"exclude_intervals\"\nintervals = [[2, 4], [1, 2]]\n"))).steps) == 1
    end
end

@testset "Excluded intervals may touch, not overlap" begin
    P = WT.Preprocessing
    rs = P.RawSeries(Union{Missing, Float64}[1.0, 2.0, 3.0], Int64[0, 5, 25], :second,
        nothing, PreparationRecord("intervals"))
    # the cut [1, 20) removes the row at 5 and 19 s: the row at 25 moves to 6
    @test P.exclude_intervals(rs, [(1, 20)]).times == [0, 6]
    @test P.exclude_intervals(rs, [(10, 20), (1, 10)]).times == [0, 6]
    @test_throws ArgumentError P.exclude_intervals(rs, [(1, 10), (5, 20)])
    @test_throws ArgumentError P.exclude_intervals(rs, [(1, 10), (5, 20)]; splice = false)
end

@testset "Time stamps outside the Int64 nanosecond range" begin
    P = WT.Preprocessing
    # 2026-11-16T00:00:00Z is 1 794 787 200 s after the epoch
    @test P.time_to_ns(1_794_787_200, :second, nothing, 1) == 1_794_787_200 * 10^9
    @test P.time_to_ns(1.7947872e9, :second, nothing, 1) == 1_794_787_200 * 10^9
    @test P.time_to_ns(DateTime(2026, 11, 16), :second, nothing, 1) == 1_794_787_200 * 10^9
    @test P.time_to_ns(1_794_787_200_000, :millisecond, nothing, 1) == 1_794_787_200 * 10^9
    # millisecond stamps read as seconds, a float beyond Int64, a date after 2262-04-11
    @test_throws ArgumentError P.time_to_ns(1_794_787_200_000, :second, nothing, 1)
    @test_throws ArgumentError P.time_to_ns(-1_794_787_200_000, :second, nothing, 1)
    @test_throws ArgumentError P.time_to_ns(1.0e30, :second, nothing, 1)
    @test_throws ArgumentError P.time_to_ns(DateTime(9999, 12, 31), :second, nothing, 1)
    # typemax(Int64) ns is 2262-04-11T23:47:16.854775807: the fraction is bounded too
    @test P.time_to_ns("2262-04-11T23:47:16.8000", :second, nothing, 1) ==
          9_223_372_036_800_000_000
    @test_throws ArgumentError P.time_to_ns("2262-04-11T23:47:16.9000", :second, nothing, 1)
end
