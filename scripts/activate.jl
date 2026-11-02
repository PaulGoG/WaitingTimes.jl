# Activate and instantiate the scripts environment silently: the package by
# path and what the scripts import beyond it (UnicodePlots for the terminal
# overview of prepare.jl).
using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)
