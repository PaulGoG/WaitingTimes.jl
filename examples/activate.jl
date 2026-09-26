# Activate and instantiate the examples environment silently. It consumes the
# package by path and the two public packages it interfaces with from GitHub;
# the first instantiation clones and precompiles them.
using Pkg
Pkg.activate(@__DIR__; io = devnull)
Pkg.instantiate(; io = devnull)
