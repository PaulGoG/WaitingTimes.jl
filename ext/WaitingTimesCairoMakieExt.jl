module WaitingTimesCairoMakieExt

using CairoMakie: CairoMakie, Axis, Figure, Label, Theme, lines!, save, scatter!, vspan!,
                  with_theme
using WaitingTimes: WaitingTimes, QuantizedSeries, WaitingTimeDistribution,
                    format_threshold, nsamples, probabilities, support, survival
using WaitingTimes.Provenance: write_toml

"publication defaults: boxed axes, no minor ticks, faint dashed grid, inward ticks"
function figure_theme()
    return Theme(
        fontsize = 14,
        figure_padding = 12,
        Axis = (
            xgridstyle = :dash, ygridstyle = :dash,
            xgridcolor = (:grey, 0.12), ygridcolor = (:grey, 0.12),
            xminorticksvisible = false, yminorticksvisible = false,
            xtickalign = 1, ytickalign = 1,
            topspinevisible = true, rightspinevisible = true
        )
    )
end

"""
    WaitingTimes.plot_series(s::QuantizedSeries; quantity_label = "", unit_label = "",
                             max_points = 20_000, size = (900, 360))

Series against time (decimated to at most `max_points` samples) with gaps
shaded; the value axis is in data units.
"""
function WaitingTimes.plot_series(s::QuantizedSeries; quantity_label::AbstractString = "",
        unit_label::AbstractString = "", max_points::Integer = 20_000, size = (900, 360))
    N = length(s)
    stride = max(1, N ÷ max_points)
    idx = 1:stride:N
    scale = 10.0^s.digits
    ylabel = isempty(quantity_label) ? "Value" : uppercasefirst(quantity_label)
    isempty(unit_label) || (ylabel *= " [" * unit_label * "]")
    fig = with_theme(figure_theme()) do
        fig = Figure(; size = size)
        ax = Axis(fig[1, 1]; xlabel = "Time [" * String(s.time_unit) * "]", ylabel = ylabel)
        for (a, b) in s.gaps
            vspan!(ax, a, b; color = (:grey, 0.25))
        end
        lines!(ax, Float64.(s.times[idx]), Float64.(s.values[idx]) ./ scale;
            color = :black, linewidth = 0.8)
        fig
    end
    return fig
end

"""
    WaitingTimes.plot_distribution(d::WaitingTimeDistribution; size = (900, 380))

Probability mass (left) and survival function (right) on logarithmic axes.
"""
function WaitingTimes.plot_distribution(d::WaitingTimeDistribution; size = (900, 380))
    nsamples(d) > 0 || throw(ArgumentError("the distribution is empty"))
    k = Float64.(support(d))
    p = probabilities(d)
    F = survival(d)
    keep = F .> 0
    unit = String(d.time_unit)
    fig = with_theme(figure_theme()) do
        fig = Figure(; size = size)
        ax1 = Axis(
            fig[1, 1]; xlabel = "Waiting time k [" * unit * "]", ylabel = "P(τ = k)",
            xscale = log10, yscale = log10)
        scatter!(ax1, k, p; color = :black, markersize = 4)
        ax2 = Axis(
            fig[1, 2]; xlabel = "Waiting time k [" * unit * "]", ylabel = "P(τ > k)",
            xscale = log10, yscale = log10)
        scatter!(ax2, k[keep], F[keep]; color = :black, markersize = 4)
        Label(fig[0, :],
            "δ = " * format_threshold(d.delta) * ", " * string(nsamples(d)) *
            " waits, " * string(d.n_right_censored) * " censored";
            fontsize = 12)
        fig
    end
    return fig
end

"""
    WaitingTimes.save_figure(path, fig; sidecar, px_per_unit = 4)

Save `fig` to `path` and write `path * ".toml"` with the `sidecar` descriptor.
"""
function WaitingTimes.save_figure(path::AbstractString, fig; sidecar::AbstractDict,
        px_per_unit::Real = 4)
    mkpath(dirname(path))
    save(path, fig; px_per_unit = px_per_unit)
    write_toml(path * ".toml", sidecar)
    return path
end

end # module
