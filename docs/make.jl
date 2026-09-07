using WaitingTimes
using Documenter

DocMeta.setdocmeta!(WaitingTimes, :DocTestSetup, :(using WaitingTimes); recursive = true)

makedocs(;
    modules = [WaitingTimes],
    authors = "Paul-Adrian Gogîță <gogitapaul@yahoo.ro>",
    sitename = "WaitingTimes.jl",
    format = Documenter.HTML(;
        canonical = "https://PaulGoG.github.io/WaitingTimes.jl",
        edit_link = "main",
        assets = String[]
    ),
    pages = [
        "Home" => "index.md",
        "Formulation" => "formulation.md",
        "Kernels" => "kernels.md",
        "Pipeline" => "pipeline.md",
        "Configuration" => "configuration.md",
        "Provenance" => "provenance.md",
        "Validation" => "validation.md",
        "API" => "api.md",
        "References" => "references.md"
    ],
    checkdocs = :exports,
    warnonly = [:missing_docs, :cross_references]
)

deploydocs(; repo = "github.com/PaulGoG/WaitingTimes.jl", devbranch = "main")
