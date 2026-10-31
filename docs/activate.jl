# Activate and instantiate the documentation environment silently; the package
# is consumed by path through [sources] in docs/Project.toml.
using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)
