"package resolution"

load(":version.bzl", version_lib = "version")

def _parse_dep(raw):
    raw = raw.strip()  # remove leading & trailing whitespace
    name = None
    version = None
    archs = None

    sqb_start_i = raw.find("[")
    if sqb_start_i != -1:
        sqb_end_i = raw.find("]")
        if sqb_end_i == -1:
            fail('invalid version string %s expected a closing brackets "]"' % raw)
        archs = raw[sqb_start_i + 1:sqb_end_i].strip().split(" ")
        raw = raw[:sqb_start_i] + raw[sqb_end_i + 1:]

    paren_start_i = raw.find("(")
    if paren_start_i != -1:
        paren_end_i = raw.find(")")
        if paren_end_i == -1:
            fail('invalid version string %s expected a closing paren ")"' % raw)
        name = raw[:paren_start_i].strip()
        version_and_constraint = raw[paren_start_i + 1:paren_end_i].strip()
        version = version_lib.parse_version_and_constraint(version_and_constraint)
        raw = raw[:paren_start_i] + raw[paren_end_i + 1:]

    # Depends: python3:any
    # is equivalent to
    # Depends: python3 [any]
    colon_i = raw.find(":")
    if colon_i != -1:
        arch_after_colon = raw[colon_i + 1:]
        raw = raw[:colon_i]
        archs = [arch_after_colon.strip()]

    name = raw.strip()
    return {"name": name, "version": version, "arch": archs}

def _parse_depends(depends_raw):
    depends = []
    for dep in depends_raw.split(","):
        if dep.find("|") != -1:
            depends.append([
                _parse_dep(adep)
                for adep in dep.split("|")
            ])
        else:
            depends.append(_parse_dep(dep))

    return depends

def _resolve_package(index, arch, name, version):
    # Get available versions of the package
    versions = index.package_get(arch, name)

    # Order packages by highest to lowest
    versions = version_lib.sort(versions, reverse = True)
    package = None
    if version:
        for va in versions:
            op, vb = version
            if version_lib.compare(va, op, vb):
                package = index.package_get(arch, name, va)

                # Since versions are ordered by hight to low, the first
                # satisfied version will be the highest version and
                # rules_distroless ignores Priority field so it's safe.
                # TODO: rethink this `break` with issue #34
                break
    elif len(versions) > 0:
        # First element in the versions list is the latest version.
        version = versions[0]
        package = index.package_get(arch, name, version)
    return package

def _resolve_all(index, arch, name, version, include_transitive):
    root_package = None
    already_recursed = {}
    unmet_dependencies = []
    dependencies = []
    has_optional_deps = False
    iteration_max = 2147483646

    stack = [(name, version)]

    for i in range(0, iteration_max + 1):
        if not len(stack):
            break
        if i == iteration_max:
            fail("resolve_dependencies exhausted the iteration")
        (name, version) = stack.pop()

        package = _resolve_package(index, arch, name, version)

        if not package:
            key = "%s~~%s" % (name, version[1] if version else "")
            unmet_dependencies.append((name, version))
            continue

        if i == 0:
            # Set the root package
            root_package = package

        key = "%s~~%s" % (package["Package"], package["Version"])

        # If we encountered package before in the transitive closure, skip it
        if key in already_recursed:
            continue

        if i != 0:
            # Add it to the dependencies
            already_recursed[key] = True
            dependencies.append(package)

        deps = []

        # Extend the lookup with all the items in the dependency closure
        if "Pre-Depends" in package and include_transitive:
            deps.extend(_parse_depends(package["Pre-Depends"]))

        # Extend the lookup with all the items in the dependency closure
        if "Depends" in package and include_transitive:
            deps.extend(_parse_depends(package["Depends"]))

        for dep in deps:
            if type(dep) == "list":
                # TODO: optional dependencies
                has_optional_deps = True
                continue

            # TODO: arch
            stack.append((dep["name"], dep["version"]))

    if has_optional_deps:
        msg = "Warning: package '{}/{}' (or one of its dependencies) "
        msg += "has optional dependencies that are not supported yet: #27"
        print(msg.format(root_package["Package"], arch))

    if unmet_dependencies:
        msg = "Warning: the following packages have unmet dependencies: {}"
        print(msg.format(",".join([up[0] for up in unmet_dependencies])))

    return root_package, dependencies

def _new(index):
    return struct(
        resolve_all = lambda **kwargs: _resolve_all(index, **kwargs),
        resolve_package = lambda **kwargs: _resolve_package(index, **kwargs),
    )

package_resolution = struct(
    new = _new,
    parse_depends = _parse_depends,
)
