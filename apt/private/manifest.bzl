"manifest"

load("@aspect_bazel_lib//lib:repo_utils.bzl", "repo_utils")
load(":lockfile.bzl", "lockfile")
load(":package_index.bzl", "package_index")
load(":util.bzl", "util")

def _parse(rctx, manifest_label):
    host_yq = Label("@yq_{}//:yq{}".format(
        repo_utils.platform(rctx),
        ".exe" if repo_utils.is_windows(rctx) else "",
    ))

    yq_args = [
        str(rctx.path(host_yq)),
        str(rctx.path(manifest_label)),
        "-o=json",
    ]

    result = rctx.execute(yq_args)
    if result.return_code:
        err = "failed to parse manifest - '{}' exited with {}: "
        err += "\nSTDOUT:\n{}\nSTDERR:\n{}"
        fail(err.format(
            " ".join(yq_args),
            result.return_code,
            result.stdout,
            result.stderr,
        ))

    return json.decode(result.stdout if result.stdout != "null" else "{}")

def _source(src):
    _ext = lambda name, ext: "%s%s" % (name, (".%s" % ext) if ext else "")

    src["url"] = src["url"].rstrip("/")

    index = "Packages"

    if "directory" in src:  # flat repo:
        src["directory"] = src["directory"].rstrip("/")
        index_path = src["directory"]
        output = "{directory}/{arch}/{index}".format(index = index, **src)
    else:  # canonical
        index_path = "dists/{dist}/{comp}/binary-{arch}".format(**src)
        output = "{dist}/{comp}/{arch}/{index}".format(index = index, **src)

    return struct(
        arch = src["arch"],
        base_url = src["url"],
        index = index,
        index_full = lambda ext: _ext(index, ext),
        output = output,
        output_full = lambda ext: _ext(output, ext),
        index_path = index_path,
        index_url = lambda ext: "/".join((src["url"], index_path, _ext(index, ext))),
    )

def _from_dict(manifest, manifest_label):
    manifest["label"] = manifest_label

    if manifest["version"] != 1:
        err = "Unsupported manifest version: {}. Please use `version: 1`"
        fail(err.format(manifest["version"]))

    for key in ("sources", "archs", "packages"):
        if type(manifest[key]) != "list":
            fail("`{}` should be an array".format(key))

    for key in ("archs", "packages"):
        dupes = util.get_dupes(manifest[key])
        if dupes:
            err = "Duplicate {}: {}. Please remove them from manifest {}"
            fail(err.format(key, dupes, manifest["label"]))

    sources = []

    for arch in manifest["archs"]:
        for src in manifest["sources"]:
            src["arch"] = arch

            channel_chunks = src["channel"].split(" ")

            # support both canonical and flat repos, see:
            # canonical: https://wiki.debian.org/DebianRepository/Format#Overview
            # flat repo: https://wiki.debian.org/DebianRepository/Format#Flat_Repository_Format
            if len(channel_chunks) > 1:  # canonical
                dist, components = channel_chunks[0], channel_chunks[1:]

                if dist.endswith("/"):
                    fail("Debian dist ends in '/' but this is not a flat repo")

                for comp in components:
                    src["dist"] = dist
                    src["comp"] = comp

                    sources.append(_source(src))
            else:  # flat
                directory = channel_chunks[0]

                if not directory.endswith("/"):
                    fail("Debian flat repo directory must end in '/'")

                src["directory"] = directory

                sources.append(_source(src))

    manifest["sources"] = sources

    return struct(**manifest)

def _lock(rctx, manifest, include_transitive):
    pkgindex = package_index.new(rctx, manifest)

    lockf = lockfile.empty(rctx)

    for arch in manifest.archs:
        for package_name in manifest.packages:
            resolved = package_index.parse_depends(package_name).pop()

            rctx.report_progress("Resolving %s" % package_name)
            package, dependencies = pkgindex.resolve_all(
                arch = arch,
                name = resolved["name"],
                version = resolved["version"],
                include_transitive = include_transitive,
            )

            if not package:
                fail("Unable to locate package `%s`" % package_name)

            lockf.add_package(package, arch, dependencies)

    return lockf

manifest = struct(
    lock = lambda rctx, manifest_label, include_transitive: _lock(
        rctx,
        _from_dict(_parse(rctx, manifest_label), manifest_label),
        include_transitive,
    ),
    # NOTE: these are exposed here for testing purposes, DO NOT USE OTHERWISE
    _source = _source,
    _from_dict = _from_dict,
    _lock = _lock,
)
