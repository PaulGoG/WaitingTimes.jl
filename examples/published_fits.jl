# Reproduction of Table 1 of Gogîță et al., J. Phys. Complex. 7 (2026) 035007
# from the distributions this package computes, with the fitting recipe of the
# 2024 analysis (legacy_fit.jl): Nelder-Mead on the renormalised
# Kolmogorov-Smirnov distance, the scale-free fit started from the
# maximum-likelihood exponent at every point of the x_min sampling grid, the
# Pareto-Tsallis fit started from (2, mean τ). The series are prepared by the
# shipped configurations, whose preprocessing states the published treatment.
#
#   julia --threads=auto examples/published_fits.jl [--out results.csv]
#
# The datasets whose inputs the shipped configurations reference; the BTC-USDT
# and automotive inputs of the paper are not distributed. The raw inputs are
# expected under data/raw/ as the configurations state.
include(joinpath(@__DIR__, "activate.jl"))

using CSV: CSV
using DataFrames: DataFrame
using Printf: @printf
using WaitingTimes

const CONFIGS = joinpath(dirname(@__DIR__), "configs")

include(joinpath(@__DIR__, "legacy_fit.jl"))

# --- Table 1 --------------------------------------------------------------------

const TABLE = [
    # dataset label, config, δ_SF, α_SF, D_SF, δ_PT, α_PT, D_PT
    ("Wind speed", "geisenheim_wind.toml", 1.0, 2.100, 1.08e-2, 32.5, 1.485, 1.22e-2),
    ("Daily solar index", "noaa_solar.toml", 0.05, 2.268, 3.07e-2, 55.0, 6.441, 1.86e-2),
    ("TEC in ionosphere", "iss_tec.toml", 5.0, 2.411, 3.04e-2, 25.0, 1.492, 2.09e-2),
    ("Sea level variations", "trieste_sea_level.toml", 1.0, 2.141, 3.45e-2, 76.0, 1.389, 3.49e-2),
    ("EUR-USD", "eur_usd.toml", 1e-4, 1.404, 1.61e-2, 3.4e-2, 0.753, 4.00e-2)
]

out = let i = findfirst(==("--out"), ARGS)
    i === nothing ? nothing : ARGS[i + 1]
end
rows = DataFrame(dataset = String[], model = String[], delta = Float64[], n_waiting = Int[],
    alpha = Float64[], alpha_published = Float64[], second = Float64[], ks = Float64[],
    ks_published = Float64[], seconds = Float64[])

for (label, config, δ_sf, α_sf, d_sf, δ_pt, α_pt, d_pt) in TABLE
    settings = load_settings(joinpath(CONFIGS, config))
    series, ids = prepare(settings)
    println("== ", label, " (", ids.series_slug, ", ", length(series), " observations)")
    τ, pmf, cdf, d = distribution_at(series, δ_sf)
    seconds = @elapsed sf = fit_scale_free(τ, cdf)
    push!(rows, (label, "scale-free", δ_sf, WaitingTimes.nsamples(d), sf.α, α_sf, Float64(sf.x_min),
        sf.ks, d_sf, seconds))
    @printf("  scale-free     δ = %-8g α = %.3f (published %.3f)  x_min = %-6d D_KS = %.2e (published %.2e)  %.1f s\n",
        δ_sf, sf.α, α_sf, sf.x_min, sf.ks, d_sf, seconds)
    τ, pmf, cdf, d = distribution_at(series, δ_pt)
    seconds = @elapsed pt = fit_pareto_tsallis(τ, pmf, cdf)
    push!(rows, (label, "Pareto-Tsallis", δ_pt, WaitingTimes.nsamples(d), pt.α, α_pt, pt.λ, pt.ks, d_pt,
        seconds))
    @printf("  Pareto-Tsallis δ = %-8g α = %.3f (published %.3f)  λ = %-8.3g D_KS = %.2e (published %.2e)  %.1f s\n",
        δ_pt, pt.α, α_pt, pt.λ, pt.ks, d_pt, seconds)
    flush(stdout)
end
out === nothing || CSV.write(out, rows)
println(rows)
