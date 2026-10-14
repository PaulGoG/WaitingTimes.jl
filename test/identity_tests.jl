# Source identity of package code: git tree hashes, manifest resolution and the
# fallback from git work tree to installed copy to bare directory.

using WaitingTimes.Provenance: active_manifest, manifest_entry, package_identity,
                               source_identity, tree_hash
using TOML: TOML

const IDENTITY_FIELDS = ("identity_source", "git_tree_sha1", "git_commit", "git_dirty",
    "repo_url", "repo_rev")
const EMPTY_TREE_SHA1 = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

"standard output of `git -C dir args...` with the trailing newline removed"
identity_git(dir, args...) = chomp(read(`git -C $dir $args`, String))

"""
Package-like directory exercising every tree-entry kind: nested trees, an
executable, a symbolic link, a multi-chunk binary blob, a non-ASCII name, names
whose git order differs from plain string order (`src.jl` before `src/`), empty
directories and a top-level `data/` ignored by `.gitignore`.
"""
function identity_fixture!(dir)
    mkpath(joinpath(dir, "src", "nested"))
    mkpath(joinpath(dir, "bin"))
    mkpath(joinpath(dir, "empty", "inner"))
    mkpath(joinpath(dir, "data"))
    write(joinpath(dir, "README.md"), "Fixture\n")
    write(joinpath(dir, "src.jl"), "# precedes src/ in git order\n")
    write(joinpath(dir, "src", "a.jl"), "a = 1\n")
    write(joinpath(dir, "src", "nested", "b.jl"), "b = 2\n")
    write(joinpath(dir, "src", "blob.bin"), UInt8.(mod.(1:200_000, 251)))
    write(joinpath(dir, "é.txt"), "non-ASCII name\n")
    write(joinpath(dir, "bin", "run.sh"), "#!/bin/sh\necho run\n")
    chmod(joinpath(dir, "bin", "run.sh"), 0o755)
    symlink("README.md", joinpath(dir, "link"))
    write(joinpath(dir, "data", "output.csv"), "x\n1\n")
    write(joinpath(dir, ".gitignore"), "/data/\n")
    return dir
end

"write a version-2 manifest holding the single entry `[[deps.Fake]]`"
function fake_manifest(path, entry)
    open(path, "w") do io
        TOML.print(io,
            Dict("julia_version" => string(VERSION), "manifest_format" => "2.0",
                "deps" => Dict("Fake" => [entry])))
    end
    return path
end

@testset "Source identity" begin
    hex40 = r"^[0-9a-f]{40}$"
    has_git = Sys.which("git") !== nothing
    has_git || @info "git not found; work-tree tests skipped"

    mktempdir() do root
        # known answers of git write-tree, independent of a git executable
        known = mkpath(joinpath(root, "known"))
        @test tree_hash(known) == EMPTY_TREE_SHA1
        write(joinpath(known, "hello.txt"), "hello\n")
        @test tree_hash(known) == "aaa96ced2d9a1c8e72c56b253a0e2fe78393feb7"
        mkpath(joinpath(known, "sub"))
        @test tree_hash(known) == "aaa96ced2d9a1c8e72c56b253a0e2fe78393feb7"
        touch(joinpath(known, "sub", "empty.txt"))
        chmod(joinpath(known, "sub", "empty.txt"), 0o755)
        @test tree_hash(known) == "18cae7463bb998b1553c093dfc37c08b49cdf18a"
        @test_throws ArgumentError tree_hash(joinpath(known, "hello.txt"))
        @test_throws ArgumentError source_identity(joinpath(root, "absent"))

        tree = identity_fixture!(joinpath(root, "tree"))
        h = tree_hash(tree)
        @test occursin(hex40, h)
        @test tree_hash(tree; exclude = ()) != h
        @test tree_hash(tree; exclude = ("data", "README.md")) != h
        mkpath(joinpath(tree, "src", "another_empty"))
        @test tree_hash(tree) == h

        # agreement with Pkg's implementation, when Pkg is loadable
        pkg_id = Base.identify_package("Pkg")
        if pkg_id !== nothing
            pkg = Base.require(pkg_id)
            pkg_hash = Base.invokelatest() do
                bytes2hex(pkg.GitTools.tree_hash(tree))
            end
            @test tree_hash(tree; exclude = ()) == pkg_hash
        end

        # bare directory
        id = source_identity(tree; manifest = nothing)
        @test all(haskey(id, k) for k in IDENTITY_FIELDS)
        @test id["identity_source"] == "directory"
        @test id["git_tree_sha1"] == h
        @test id["git_commit"] == "" && id["repo_url"] == "" && id["repo_rev"] == ""
        @test id["git_dirty"] === false

        if has_git
            repo = cp(tree, joinpath(root, "repo"))
            identity_git(repo, "init", "-q")
            identity_git(repo, "config", "user.name", "Fixture")
            identity_git(repo, "config", "user.email", "fixture@example.org")
            identity_git(repo, "config", "commit.gpgsign", "false")
            identity_git(repo, "add", "-A")
            identity_git(repo, "commit", "-q", "--no-verify", "-m", "fixture")
            head = identity_git(repo, "rev-parse", "HEAD")
            head_tree = identity_git(repo, "rev-parse", "HEAD^{tree}")
            @test isempty(identity_git(repo, "ls-files", "data"))
            @test tree_hash(repo) == head_tree
            @test tree_hash(joinpath(repo, "src")) ==
                  identity_git(repo, "rev-parse", "HEAD:src")

            id = source_identity(repo; manifest = nothing)
            @test id["identity_source"] == "work_tree"
            @test id["git_commit"] == head
            @test id["git_tree_sha1"] == head_tree
            @test id["git_dirty"] === false
            @test id["repo_url"] == "" && id["repo_rev"] == ""

            # a subdirectory is not the top level of the work tree
            id = source_identity(joinpath(repo, "src"); manifest = nothing)
            @test id["identity_source"] == "directory"
            @test id["git_commit"] == ""
            @test id["git_tree_sha1"] == identity_git(repo, "rev-parse", "HEAD:src")

            # the same content without .git
            bare = cp(repo, joinpath(root, "bare"))
            rm(joinpath(bare, ".git"); recursive = true)
            id = source_identity(bare; manifest = nothing)
            @test id["identity_source"] == "directory"
            @test id["git_tree_sha1"] == head_tree
            @test id["git_commit"] == ""
            @test id["git_dirty"] === false

            # no git executable on the search path
            withenv("PATH" => mkpath(joinpath(root, "bin_without_git"))) do
                @test Sys.which("git") === nothing
                id = source_identity(repo; manifest = nothing)
                @test id["identity_source"] == "directory"
                @test id["git_tree_sha1"] == head_tree
            end

            # untracked files leave the checkout clean, a tracked change does not
            write(joinpath(repo, "untracked.txt"), "untracked\n")
            @test source_identity(repo; manifest = nothing)["git_dirty"] === false
            write(joinpath(repo, "src", "a.jl"), "a = 3\n")
            id = source_identity(repo; manifest = nothing)
            @test id["git_dirty"] === true
            @test id["git_tree_sha1"] == head_tree

            # a committed top-level data/ is hashed with exclude = ()
            identity_git(repo, "checkout", "--", "src/a.jl")
            rm(joinpath(repo, "untracked.txt"))
            identity_git(repo, "add", "-f", "data")
            identity_git(repo, "commit", "-q", "--no-verify", "-m", "data")
            head_tree = identity_git(repo, "rev-parse", "HEAD^{tree}")
            @test tree_hash(repo; exclude = ()) == head_tree
            @test tree_hash(repo) != head_tree
        end

        # installed copy matched through the manifest
        installed = cp(tree, joinpath(root, "installed"))
        uuid = Base.UUID("5a3c1d6e-7f80-4b2a-9c1d-0e2f3a4b5c6d")
        rev = "0123456789abcdef0123456789abcdef01234567"
        url = "https://example.org/Fake.jl.git"
        entry = Dict("uuid" => string(uuid), "version" => "0.1.0",
            "git-tree-sha1" => h, "repo-url" => url, "repo-rev" => rev)
        manifest = fake_manifest(joinpath(root, "Manifest.toml"), entry)
        @test manifest_entry(manifest, uuid)["git-tree-sha1"] == h
        @test manifest_entry(manifest, Base.UUID(0)) === nothing
        @test manifest_entry(joinpath(root, "absent.toml"), uuid) === nothing

        id = source_identity(installed; uuid, manifest)
        @test id["identity_source"] == "manifest"
        @test id["git_tree_sha1"] == h
        @test id["git_commit"] == rev
        @test id["repo_url"] == url && id["repo_rev"] == rev
        @test id["git_dirty"] === false
        @test source_identity(installed; manifest)["identity_source"] == "directory"
        @test source_identity(installed; uuid = Base.UUID(0), manifest)["identity_source"] ==
              "directory"

        fake_manifest(manifest, merge(entry, Dict("repo-rev" => "main")))
        id = source_identity(installed; uuid, manifest)
        @test id["identity_source"] == "manifest"
        @test id["git_commit"] == "" && id["repo_rev"] == "main"

        # a package shipping a top-level data/ is recorded with it
        fake_manifest(manifest,
            merge(entry, Dict("git-tree-sha1" => tree_hash(installed; exclude = ()))))
        @test source_identity(installed; uuid, manifest)["git_dirty"] === false

        fake_manifest(manifest, entry)
        write(joinpath(installed, "src", "a.jl"), "a = 3\n")
        id = source_identity(installed; uuid, manifest)
        @test id["identity_source"] == "manifest"
        @test id["git_tree_sha1"] == h
        @test id["git_dirty"] === true

        # a developed package (path entry) is not an installed copy
        fake_manifest(manifest, Dict("uuid" => string(uuid), "path" => installed))
        @test source_identity(installed; uuid, manifest)["identity_source"] == "directory"

        # manifest resolution of code loading
        candidates = ("JuliaManifest-v$(VERSION.major).$(VERSION.minor).toml",
            "Manifest-v$(VERSION.major).$(VERSION.minor).toml",
            "JuliaManifest.toml", "Manifest.toml")
        active = active_manifest()
        @test active !== nothing && isfile(active)
        @test basename(active) in candidates

        envs = mkpath(joinpath(root, "envs"))
        @test active_manifest(joinpath(envs, "absent", "Project.toml")) === nothing
        plain = mkpath(joinpath(envs, "plain"))
        write(joinpath(plain, "Project.toml"), "")
        @test active_manifest(joinpath(plain, "Project.toml")) === nothing
        touch(joinpath(plain, "Manifest.toml"))
        @test active_manifest(joinpath(plain, "Project.toml")) ==
              joinpath(plain, "Manifest.toml")
        touch(joinpath(plain, candidates[2]))
        @test active_manifest(joinpath(plain, "Project.toml")) ==
              joinpath(plain, candidates[2])
        write(joinpath(plain, "Project.toml"), "manifest = \"custom/M.toml\"\n")
        @test active_manifest(joinpath(plain, "Project.toml")) ==
              joinpath(plain, candidates[2])
        touch(joinpath(mkpath(joinpath(plain, "custom")), "M.toml"))
        @test active_manifest(joinpath(plain, "Project.toml")) ==
              joinpath(plain, "custom", "M.toml")

        workspace = mkpath(joinpath(envs, "workspace"))
        write(joinpath(workspace, "Project.toml"), "[workspace]\nprojects = [\"member\"]\n")
        touch(joinpath(workspace, "Manifest.toml"))
        for name in ("member", "outsider")
            write(joinpath(mkpath(joinpath(workspace, name)), "Project.toml"), "")
            touch(joinpath(workspace, name, "Manifest.toml"))
        end
        @test active_manifest(joinpath(workspace, "member", "Project.toml")) ==
              joinpath(workspace, "Manifest.toml")
        @test active_manifest(joinpath(workspace, "outsider", "Project.toml")) ==
              joinpath(workspace, "outsider", "Manifest.toml")
    end

    id = package_identity()
    @test all(haskey(id, k) for k in IDENTITY_FIELDS)
    @test id["identity_source"] in ("work_tree", "manifest", "directory")
    @test occursin(hex40, id["git_tree_sha1"])
    @test id["git_dirty"] isa Bool
end
