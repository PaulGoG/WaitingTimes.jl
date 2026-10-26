# Build the documentation site into docs/build/.
#
#   julia docs/make.jl
include(joinpath(@__DIR__, "activate.jl"))

using WaitingTimes
using Documenter
using Literate

DocMeta.setdocmeta!(WaitingTimes, :DocTestSetup, :(using WaitingTimes); recursive = true)

const LITERATE_SOURCES = joinpath(@__DIR__, "src", "literate")
const GENERATED = joinpath(@__DIR__, "src", "generated")
mkpath(GENERATED)
for file in readdir(LITERATE_SOURCES; join = true)
    endswith(file, ".jl") && Literate.markdown(file, GENERATED; documenter = true)
end

makedocs(;
    modules = [WaitingTimes],
    authors = "Paul-Adrian Gogîță",
    sitename = "WaitingTimes.jl",
    format = Documenter.HTML(;
        canonical = "https://PaulGoG.github.io/WaitingTimes.jl",
        edit_link = "main",
        assets = String[],
        size_threshold = 400 * 1024, size_threshold_warn = 200 * 1024
    ),
    pages = [
        "Home" => "index.md",
        "Formulation" => "formulation.md",
        "Kernels" => "kernels.md",
        "Pipeline" => "pipeline.md",
        "Configuration" => "configuration.md",
        "Provenance" => "provenance.md",
        "Validation" => "validation.md",
        "Interfacing" => "interfacing.md",
        "Producers" => "producers.md",
        "Downstream example" => "generated/downstream_fit.md",
        "API" => "api.md",
        "Internals" => "internals.md",
        "References" => "references.md"
    ],
    checkdocs = :public,
    warnonly = [:cross_references]
)

deploydocs(; repo = "github.com/PaulGoG/WaitingTimes.jl", devbranch = "main")
