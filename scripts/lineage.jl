# Print the lineage of a collection directory or of a file inside one:
# collection, series (with its preparation steps) and dataset, plus sessions.
#
#   julia scripts/lineage.jl PATH
include(joinpath(dirname(@__DIR__), "activate.jl"))

using TOML

length(ARGS) == 1 || error("usage: lineage.jl PATH")
path = abspath(ARGS[1])
dir = isdir(path) ? path : dirname(path)
while !isfile(joinpath(dir, "metadata.toml")) && dirname(dir) != dir
    global dir = dirname(dir)
end
isfile(joinpath(dir, "metadata.toml")) || error("no metadata.toml above $path")
meta = TOML.parsefile(joinpath(dir, "metadata.toml"))

println("collection ", meta["artefact"]["id"], "  created ", meta["artefact"]["created"])
println("  identity ", meta["identity"])
series = meta["series"]
println("series     ", series["id"], "  (", series["n_observations"], " observations, ",
    series["n_gaps"], " gaps, digits ", series["digits"], ", unit ", series["time_unit"], ")")
for step in series["record"]["steps"]
    println("    step ", step["op"], "  ", step["parameters"])
end
dataset = meta["dataset"]
println("dataset    ", dataset["id"], "  ", dataset["identity"])
if !isempty(dataset["descriptor"])
    for (k, v) in dataset["descriptor"]
        println("    ", k, ": ", v)
    end
end
println("sessions   ", length(meta["sessions"]))
for s in meta["sessions"]
    println("    ", s["id"], "  kernel ", s["kernel"], "  git ", s["git"], "  computed ",
        s["n_computed"], "  skipped ", s["n_skipped"], "  reference checks ", s["n_reference_checks"])
end
