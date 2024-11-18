"unit tests for resolution of package dependencies"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:apt_deb_repository.bzl", deb_repository = "DO_NOT_DEPEND_ON_THIS_TEST_ONLY")
load("//apt/private:apt_dep_resolver.bzl", "dependency_resolver")
load("//apt/tests:mocks.bzl", "mock")

_test_version = "2.38.1-5"
_test_arch = "amd64"

def _make_index():
    idx = deb_repository.new()
    resolution = dependency_resolver.new(idx)

    def _add_package(idx, **kwargs):
        kwargs["architecture"] = kwargs.get("architecture", _test_arch)
        kwargs["version"] = kwargs.get("version", _test_version)
        r = "\n".join(["{}: {}".format(item[0].title(), item[1]) for item in kwargs.items()])
        idx.parse_package_index(r)

    return struct(
        add_package = lambda **kwargs: _add_package(idx, **kwargs),
        mock_rctx = mock.rctx(),
        resolution = resolution,
        reset = lambda: idx.reset(),
    )

def _resolve_optionals_test(ctx):
    env = unittest.begin(ctx)

    idx = _make_index()

    # Should pick the first alternative
    idx.add_package(package = "libc6-dev")
    idx.add_package(package = "eject", depends = "libc6-dev | libc-dev")

    root_package, dependencies = idx.resolution.resolve(
        idx.mock_rctx,
        arch = _test_arch,
        name = "eject",
        version = ("=", _test_version),
    )
    asserts.equals(env, "eject", root_package["Package"])
    asserts.equals(env, "libc6-dev", dependencies[0]["Package"])
    asserts.equals(env, 1, len(dependencies))

    return unittest.end(env)

resolve_optionals_test = unittest.make(_resolve_optionals_test)

def _resolve_arch_specific_packages_test(ctx):
    env = unittest.begin(ctx)

    idx = _make_index()

    #  Should pick bar for amd64 and foo for i386
    idx.add_package(package = "foo", architecture = "i386")
    idx.add_package(package = "bar", architecture = "amd64")
    idx.add_package(package = "glibc", architecture = "all", depends = "foo [i386], bar [amd64]")

    # bar for amd64
    root_package, dependencies = idx.resolution.resolve(
        idx.mock_rctx,
        arch = "amd64",
        name = "glibc",
        version = ("=", _test_version),
    )
    asserts.equals(env, "glibc", root_package["Package"])
    asserts.equals(env, "all", root_package["Architecture"])
    asserts.equals(env, "bar", dependencies[0]["Package"])
    asserts.equals(env, 1, len(dependencies))

    # foo for i386
    root_package, dependencies = idx.resolution.resolve(
        idx.mock_rctx,
        arch = "i386",
        name = "glibc",
        version = ("=", _test_version),
    )
    asserts.equals(env, "glibc", root_package["Package"])
    asserts.equals(env, "all", root_package["Architecture"])
    asserts.equals(env, "foo", dependencies[0]["Package"])
    asserts.equals(env, 1, len(dependencies))

    return unittest.end(env)

resolve_arch_specific_packages_test = unittest.make(_resolve_arch_specific_packages_test)

def _resolve_aliases(ctx):
    env = unittest.begin(ctx)

    idx = _make_index()

    idx.add_package(package = "foo", depends = "bar (>= 1.0)")
    idx.add_package(package = "bar", version = "0.9")
    idx.add_package(package = "bar-plus", provides = "bar (= 1.0)")

    root_package, dependencies = idx.resolution.resolve(
        idx.mock_rctx,
        arch = "amd64",
        name = "foo",
        version = ("=", _test_version),
    )
    asserts.equals(env, "foo", root_package["Package"])
    asserts.equals(env, "amd64", root_package["Architecture"])
    asserts.equals(env, "bar-plus", dependencies[0]["Package"])
    asserts.equals(env, 1, len(dependencies))
    idx.reset()

    idx.add_package(package = "foo", depends = "bar (>= 1.0)")
    idx.add_package(package = "bar", version = "0.9")
    idx.add_package(package = "bar-plus", provides = "bar (= 1.0)")
    idx.add_package(package = "bar-clone", provides = "bar")

    root_package, dependencies = idx.resolution.resolve(
        idx.mock_rctx,
        arch = "amd64",
        name = "foo",
        version = ("=", _test_version),
    )
    asserts.equals(env, "foo", root_package["Package"])
    asserts.equals(env, "amd64", root_package["Architecture"])
    asserts.equals(env, "bar-plus", dependencies[0]["Package"])
    asserts.equals(env, 1, len(dependencies))

    return unittest.end(env)

resolve_aliases_test = unittest.make(_resolve_aliases)

_TEST_SUITE_PREFIX = "apt_dep_resolver/"

def apt_dep_resolver_tests():
    resolve_optionals_test(name = _TEST_SUITE_PREFIX + "resolve_optionals")
    resolve_arch_specific_packages_test(name = _TEST_SUITE_PREFIX + "resolve_arch_specific")
    resolve_aliases_test(name = _TEST_SUITE_PREFIX + "resolve_aliases")
