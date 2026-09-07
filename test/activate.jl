# Activate and instantiate the test environment silently; the package itself is
# consumed by path through [sources] in test/Project.toml.
using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)
