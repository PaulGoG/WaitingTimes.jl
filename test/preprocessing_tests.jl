@testset "Configuration and preprocessing consolidation" begin
    D(pairs...) = Dict{String, Any}(pairs...)

    # one table of operations, one table of transforms, the same twelve names
    op_names = Set(["select_range", "exclude_intervals", "round",
        "trailing_mean_fluctuations", "log_returns", "log_levels", "differences",
        "centered_moving_average", "clip_quantile", "clip_sigma", "clip_extremes",
        "collapse_ties"])
    @test Set(keys(WT.Config.PREPROCESSING_OPS)) ==
          Set(keys(WT.Preprocessing.STEP_TRANSFORMS)) == op_names

    # slug tags, absent optional keys taking the operation's defaults
    tags = [
        "trailing30" => D("op" => "trailing_mean_fluctuations", "window" => 30),
        "trailing30scaled" => D("op" => "trailing_mean_fluctuations", "window" => 30,
            "denominator" => "scale"),
        "trailing30abs" => D("op" => "trailing_mean_fluctuations", "window" => 30,
            "denominator" => "none"),
        "round2" => D("op" => "round", "digits" => 2),
        "cma5" => D("op" => "centered_moving_average", "window" => 5),
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

    # grid arithmetic
    @test WT.on_grid(0.25, 2) && !WT.on_grid(0.255, 2)
    @test WT.GRID_TOLERANCE == 1e-6
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
            linear * "[gaps]\ndetect = \"threshold\"\nthreshold = 2\ncadence = 1\n"))
        @test_logs (:warn, r"step") match_mode = :any load_settings(config(
            "[thresholds]\nmode = \"explicit\"\nvalues = [0.05, 0.1]\nstep = 0.05\n"))
        settings = @test_logs (:warn, r"unknown configuration key") match_mode = :any load_settings(config(
            linear; input = "quantity_label = \"level\"\n"))
        @test settings isa WT.Settings
    end
end
