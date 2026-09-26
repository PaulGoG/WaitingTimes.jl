# Activate and instantiate the device-test environment silently; the package is
# consumed by path through [sources] in test/device/Project.toml.
using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)
