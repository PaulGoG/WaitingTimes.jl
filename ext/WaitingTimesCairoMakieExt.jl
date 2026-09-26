module WaitingTimesCairoMakieExt

using CairoMakie: CairoMakie, Axis, Figure, Legend, LineElement, PolyElement, Theme,
                  linkxaxes!, lines!, save, scatter!, stairs!, text!, vspan!, with_theme
using CairoMakie.Makie.MathTeXEngine: texfont
using WaitingTimes: WaitingTimes, QuantizedSeries, WaitingTimeDistribution, duration,
                    format_threshold, nsamples, probabilities, support, survival
using WaitingTimes.Provenance: write_toml

"unicode superscript digits for decade labels"
const SUPERSCRIPTS = Dict('-' => '⁻', '0' => '⁰', '1' => '¹', '2' => '²', '3' => '³',
    '4' => '⁴', '5' => '⁵', '6' => '⁶', '7' => '⁷', '8' => '⁸', '9' => '⁹')

"""
    WaitingTimes.figure_theme()

Publication theme of the package: Computer Modern fonts, base font size 26,
boxed axes with inward ticks, no minor ticks, faint dashed grid, data lines of
width 3, markers of size 14 with a stroke, frameless horizontal legends.
"""
function WaitingTimes.figure_theme()
    return Theme(
        fonts = (;
            regular = texfont(:text), bold = texfont(:bold), italic = texfont(:italic)),
        fontsize = 26,
        figure_padding = 10,
        linewidth = 3,
        markersize = 14,
        Axis = (
            spinewidth = 1.5,
            xticklabelsize = 22, yticklabelsize = 22,
            xgridstyle = :dash, ygridstyle = :dash,
            xgridcolor = (:grey, 0.12), ygridcolor = (:grey, 0.12),
            xminorticksvisible = false, yminorticksvisible = false,
            xtickalign = 1, ytickalign = 1,
            topspinevisible = true, rightspinevisible = true
        ),
        Scatter = (strokewidth = 1.5,),
        Legend = (framevisible = false, orientation = :horizontal, titlefont = :bold)
    )
end

function decade_label(p::Integer)
    p == 0 ? "1" : p == 1 ? "10" :
                   "10" * map(c -> SUPERSCRIPTS[c], string(p))
end

"""
    WaitingTimes.decade_ticks(lo::Integer, hi::Integer)

Tick positions `10^lo, …, 10^hi` with labels `1`, `10`, `10²`, … for a
logarithmic axis; pass the result as `xticks` or `yticks`.
"""
function WaitingTimes.decade_ticks(lo::Integer, hi::Integer)
    lo <= hi || throw(ArgumentError("decade range is empty: $lo > $hi"))
    return (10.0 .^ (lo:hi), [decade_label(p) for p in lo:hi])
end

"decades enclosing the positive values `x`"
function enclosing_decades(x)
    lo = floor(Int, log10(minimum(x)))
    hi = ceil(Int, log10(maximum(x)))
    return lo, max(hi, lo + 1)
end

"integer tick labels with thousands separated by spaces"
function integer_ticks(values)
    return [replace(string(round(Int, v)), r"(?<=\d)(?=(\d{3})+$)" => " ") for v in values]
end

"""
    WaitingTimes.plot_series(s::QuantizedSeries; quantity_label = "", unit_label = "",
                             max_points = 5_000, size = (900, 600))

Series against time, decimated to at most `max_points` samples, with the gaps
shaded; when gaps exist a legend on top names the series and states the gap
count and their share of the record. The value axis is in data units.
"""
function WaitingTimes.plot_series(s::QuantizedSeries; quantity_label::AbstractString = "",
        unit_label::AbstractString = "", max_points::Integer = 5_000, size = (900, 600))
    N = length(s)
    stride = max(1, N ÷ max_points)
    idx = 1:stride:N
    scale = 10.0^s.digits
    label = isempty(quantity_label) ? "Value" : uppercasefirst(quantity_label)
    ylabel = isempty(unit_label) ? label : label * " [" * unit_label * "]"
    fig = with_theme(WaitingTimes.figure_theme()) do
        fig = Figure(; size = size)
        ax = Axis(
            fig[1, 1]; xlabel = "Time [" * String(s.time_unit) * "]", ylabel = ylabel,
            xtickformat = integer_ticks)
        for (a, b) in s.gaps
            vspan!(ax, a, b; color = (:grey, 0.25))
        end
        lines!(ax, Float64.(s.times[idx]), Float64.(s.values[idx]) ./ scale; color = :black)
        if !isempty(s.gaps)
            covered = sum(b - a for (a, b) in s.gaps)
            share = round(100 * covered / max(duration(s), 1); digits = 1)
            Legend(fig[0, 1],
                [LineElement(; color = :black), PolyElement(; color = (:grey, 0.25))],
                [label, "$(length(s.gaps)) gaps, $share % of the record"])
        end
        fig
    end
    return fig
end

"""
    WaitingTimes.plot_distribution(d::WaitingTimeDistribution; size = (1200, 600))

Probability mass (left, markers) and survival function (right, staircase) on
logarithmic axes sharing the waiting-time axis, with the threshold, the number
of waiting times and the right-censored count annotated.
"""
function WaitingTimes.plot_distribution(d::WaitingTimeDistribution; size = (1200, 600))
    nsamples(d) > 0 || throw(ArgumentError("the distribution is empty"))
    k = Float64.(support(d))
    p = probabilities(d)
    F = survival(d)
    keep = F .> 0
    unit = String(d.time_unit)
    xlabel = "Waiting time k [" * unit * "]"
    xlo, xhi = enclosing_decades(k)
    plo, phi = enclosing_decades(p)
    Flo, Fhi = enclosing_decades(F[keep])
    annotation = "δ = " * format_threshold(d.delta) * "\n" * string(nsamples(d)) *
                 " waiting times\n" * string(d.n_right_censored) * " right-censored"
    fig = with_theme(WaitingTimes.figure_theme()) do
        fig = Figure(; size = size)
        ax1 = Axis(fig[1, 1]; xlabel = xlabel, ylabel = "P(τ = k)",
            xscale = log10, yscale = log10, xticks = WaitingTimes.decade_ticks(xlo, xhi),
            yticks = WaitingTimes.decade_ticks(plo, min(phi, 0)))
        scatter!(ax1, k, p; color = :black, strokecolor = :black)
        text!(ax1, 0.97, 0.97; text = annotation, space = :relative,
            align = (:right, :top), fontsize = 21)
        ax2 = Axis(fig[1, 2]; xlabel = xlabel, ylabel = "P(τ > k)",
            xscale = log10, yscale = log10, xticks = WaitingTimes.decade_ticks(xlo, xhi),
            yticks = WaitingTimes.decade_ticks(Flo, min(Fhi, 0)))
        stairs!(ax2, k[keep], F[keep]; color = :black, step = :post)
        linkxaxes!(ax1, ax2)
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
