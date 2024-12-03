"repository rule for generating a dependency graph from a lockfile."

load(":lockfile.bzl", "lockfile")
load(":starlark_codegen_utils.bzl", "starlark_codegen_utils")
load(":util.bzl", "util")

# header template for packages.bzl file
_DEB_IMPORT_HEADER_TMPL = '''\
"""Generated by rules_distroless. DO NOT EDIT."""
load("@rules_distroless//apt/private:deb_import.bzl", "deb_import")

# buildifier: disable=function-docstring
def {}_packages():
'''

# deb_import template for packages.bzl file
_DEB_IMPORT_TMPL = '''\
    deb_import(
        name = "{name}",
        urls = {urls},
        sha256 = "{sha256}",
    )
'''

_PACKAGE_TEMPLATE = '''\
"""Generated by rules_distroless. DO NOT EDIT."""

alias(
    name = "data",
    actual = select({data_targets}),
    visibility = ["//visibility:public"],
)

alias(
    name = "control",
    actual = select({control_targets}),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "{target_name}",
    srcs = select({deps}) + [":data"],
    visibility = ["//visibility:public"],
)
'''

_ROOT_BUILD_TMPL = """\
"Generated by rules_distroless. DO NOT EDIT."

load("@rules_distroless//apt:defs.bzl", "dpkg_status")
load("@rules_distroless//distroless:defs.bzl", "flatten")

exports_files(['packages.bzl'])

# Map Debian architectures to platform CPUs.
#
# For more info on Debian architectures, see:
#     * https://wiki.debian.org/SupportedArchitectures
#     * https://wiki.debian.org/ArchitectureSpecificsMemo
#     * https://www.debian.org/releases/stable/amd64/ch02s01.en.html#idm186
#
# For more info on Bazel's platforms CPUs see:
#     * https://github.com/bazelbuild/platforms/blob/main/cpu/BUILD
_ARCHITECTURE_MAP = {{
    "amd64": "x86_64",
    "arm64": "arm64",
    "ppc64el": "ppc64le",
    "mips64el": "mips64",
    "s390x": "s390x",
    "i386": "x86_32",
    "armhf": "armv7e-mf",
    "all": "all",
}}

_ARCHITECTURES = {architectures}

[
   config_setting(
    name = os + "_" + arch,
    constraint_values = [
       "@platforms//os:" + os,
       "@platforms//cpu:" + _ARCHITECTURE_MAP[arch],
    ],
  )
  for os in ["linux"]
  for arch in _ARCHITECTURES
]


alias(
    name = "lock",
    actual = "@{target_name}_resolve//:lock",
    visibility = ["//visibility:public"],
)

# List of installed packages. For now it's private.
_PACKAGES = {packages}

# Creates /var/lib/dpkg/status with installed package information.
dpkg_status(
    name = "dpkg_status",
    controls = select({{
        "//:linux_%s" % arch: ["//%s:control" % package for package in packages]
        for arch, packages in _PACKAGES.items()
    }}),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "packages",
    srcs = select({{
        "//:linux_%s" % arch: ["//%s" % package for package in packages]
        for arch, packages in _PACKAGES.items()
    }}),
    visibility = ["//visibility:public"],
)


# A filegroup that contains all the packages and the dpkg status file.
filegroup(
    name = "{target_name}",
    srcs = [
        ":dpkg_status",
        ":packages",
    ],
    visibility = ["//visibility:public"],
)

flatten(
    name = "flat",
    tars = [
        "{target_name}",
    ],
    deduplicate = True,
    visibility = ["//visibility:public"],
)
"""

def _deb_translate_lock_impl(rctx):
    lock_content = rctx.attr.lock_content
    package_template = rctx.read(rctx.attr.package_template)
    lockf = lockfile.from_json(rctx, lock_content if lock_content else rctx.read(rctx.attr.lock))

    package_defs = []

    if not lock_content:
        package_defs = [_DEB_IMPORT_HEADER_TMPL.format(rctx.attr.name)]

        if len(lockf.packages()) < 1:
            package_defs.append("   pass")

    # TODO: rework lockfile to include architecure information
    architectures = {}
    packages = {}

    for (package) in lockf.packages():
        package_key = lockfile.make_package_key(
            package["name"],
            package["version"],
            package["arch"],
        )

        if package["arch"] not in architectures:
            architectures[package["arch"]] = []

        if package["name"] not in architectures[package["arch"]]:
            architectures[package["arch"]].append(package["name"])

        if package["name"] not in packages:
            packages[package["name"]] = []
        if package["arch"] not in packages[package["name"]]:
            packages[package["name"]].append(package["arch"])

        if not lock_content:
            package_defs.append(
                _DEB_IMPORT_TMPL.format(
                    name = "%s_%s" % (rctx.attr.name, package_key),
                    package_name = package["name"],
                    urls = [package["url"]],
                    sha256 = package["sha256"],
                ),
            )

        repo_name = "%s%s_%s" % ("@" if lock_content else "", rctx.attr.name, package_key)

        rctx.file(
            "%s/%s/BUILD.bazel" % (package["name"], package["arch"]),
            package_template.format(
                target_name = package["arch"],
                data_targets = '"@%s//:data"' % repo_name,
                control_targets = '"@%s//:control"' % repo_name,
                src = '"@%s//:data"' % repo_name,
                deps = starlark_codegen_utils.to_list_attr([
                    "//%s/%s" % (dep["name"], package["arch"])
                    for dep in package["dependencies"]
                ]),
                urls = [package["url"]],
                name = package["name"],
                arch = package["arch"],
                sha256 = package["sha256"],
                repo_name = "%s" % repo_name,
            ),
        )

    # TODO: rework lockfile to include architecure information and merge these two loops
    for package_name, package_archs in packages.items():
        rctx.file(
            "%s/BUILD.bazel" % (package_name),
            _PACKAGE_TEMPLATE.format(
                target_name = package_name,
                data_targets = starlark_codegen_utils.to_dict_attr({
                    "//:linux_%s" % arch: "//%s/%s:data" % (package_name, arch)
                    for arch in package_archs
                }),
                control_targets = starlark_codegen_utils.to_dict_attr({
                    "//:linux_%s" % arch: "//%s/%s:control" % (package_name, arch)
                    for arch in package_archs
                }),
                deps = starlark_codegen_utils.to_dict_list_attr({
                    "//:linux_%s" % arch: ["//%s/%s" % (package_name, arch)]
                    for arch in package_archs
                }),
            ),
        )

    rctx.file("packages.bzl", "\n".join(package_defs))
    rctx.file("BUILD.bazel", _ROOT_BUILD_TMPL.format(
        target_name = util.get_repo_name(rctx.attr.name),
        packages = starlark_codegen_utils.to_dict_list_attr(architectures),
        architectures = starlark_codegen_utils.to_list_attr(architectures.keys()),
    ))

deb_translate_lock = repository_rule(
    implementation = _deb_translate_lock_impl,
    attrs = {
        "lock": attr.label(),
        "lock_content": attr.string(doc = "INTERNAL: DO NOT USE"),
        "package_template": attr.label(default = "//apt/private:package.BUILD.tmpl"),
    },
)
