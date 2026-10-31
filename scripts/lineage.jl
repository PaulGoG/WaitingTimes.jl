# Print the lineage of a collection directory or of a file inside one:
# collection, series (with its preparation steps), dataset and source
# descriptor, the code identity and environment of WaitingTimes, the
# partitions and the sessions.
#
#   julia scripts/lineage.jl PATH
include(joinpath(dirname(@__DIR__), "activate.jl"))

using WaitingTimes
using WaitingTimes.Provenance: read_toml

"collection directory holding `path`: the nearest ancestor with a metadata.toml"
function collection_dir(path::AbstractString)
    dir = isdir(path) ? path : dirname(path)
    while !isfile(joinpath(dir, "metadata.toml")) && dirname(dir) != dir
        dir = dirname(dir)
    end
    isfile(joinpath(dir, "metadata.toml")) || error("no metadata.toml above $path")
    return dir
end

function lineage(path::AbstractString)
    c = load_collection(collection_dir(path))
    meta = c.metadata
    println("collection ", c.id, "  created ", meta["artefact"]["created"])
    println("  identity ", meta["identity"])
    series = meta["series"]
    println("series     ", series["id"], "  (", c.n_observations, " observations, ",
        c.n_gaps, " gaps, digits ", c.digits, ", unit ", c.time_unit, ")")
    for step in series["record"]["steps"]
        println("    step ", step["op"], "  ", step["parameters"])
    end
    dataset = meta["dataset"]
    println("dataset    ", dataset["id"], "  ", dataset["identity"])
    for (k, v) in dataset["descriptor"]
        println("    ", k, ": ", v)
    end
    descriptor = source_descriptor(c)
    if descriptor !== nothing
        println("source     ", meta["source"]["file"], "  sha256 ", meta["source"]["sha256"])
        summary = WaitingTimes.source_summary(c)
        println("    producer ",
            isempty(summary.producer) ? "unknown" :
            strip(summary.producer * " " * summary.producer_version),
            "  tree ", isempty(summary.git_tree_sha1) ? "-" : summary.git_tree_sha1,
            summary.git_dirty ? " (dirty)" : "")
        for (k, v) in descriptor
            v isa AbstractDict || println("    ", k, ": ", v)
        end
    end
    if haskey(meta, "producer")
        producer = meta["producer"]
        println("producer   ", producer["name"], " ", producer["version"], "  tree ",
            producer["git_tree_sha1"], producer["git_dirty"] ? " (dirty)" : "", "  commit ",
            isempty(producer["git_commit"]) ? "-" : producer["git_commit"], "  from the ",
            producer["identity_source"])
    end
    if haskey(meta, "environment")
        println("environment manifest ", meta["environment"]["manifest_file"], "  sha256 ",
            meta["environment"]["manifest_sha256"])
    end
    println("partitions ", length(c.index),
        isempty(c.index) ? "" :
        "  from delta = " * c.index[1]["delta"] * " to " * c.index[end]["delta"])
    sessions = get(meta, "sessions", Any[])
    println("sessions   ", length(sessions))
    for entry in sessions
        file = joinpath(c.dir, "sessions", entry["id"] * ".toml")
        if isfile(file)
            record = read_toml(file)
            println("    ", record["id"], "  kernel ", record["kernel"], "  git ",
                record["git"], "  computed ", length(get(record, "deltas_computed", Any[])),
                "  skipped ", length(get(record, "deltas_skipped", Any[])),
                "  reference checks ", length(get(record, "reference_checks", Any[])),
                haskey(record, "status") ? "  status " * record["status"] : "")
        else
            println(
                "    ", entry["id"], "  kernel ", entry["kernel"], "  git ", entry["git"],
                "  computed ", entry["n_computed"], "  skipped ", entry["n_skipped"],
                "  reference checks ", entry["n_reference_checks"])
        end
    end
    return nothing
end

length(ARGS) == 1 || error("usage: lineage.jl PATH")
lineage(abspath(ARGS[1]))
