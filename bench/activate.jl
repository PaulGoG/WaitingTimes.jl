# Activate and instantiate the benchmark environment silently; the package is
# consumed by path through [sources] in bench/Project.toml.
using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)
