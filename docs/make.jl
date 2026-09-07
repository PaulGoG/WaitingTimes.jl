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
    ]
)

deploydocs(;
    repo = "github.com/PaulGoG/WaitingTimes.jl",
    devbranch = "main"
)
