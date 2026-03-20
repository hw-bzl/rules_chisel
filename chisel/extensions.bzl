"""Bzlmod extension for Chisel Maven dependencies."""

load("@rules_jvm_external//:defs.bzl", "maven_install")
load("@rules_jvm_external//private/extensions:download_pinned_deps.bzl", "download_pinned_deps")
load("@rules_jvm_external//private/rules:v1_lock_file.bzl", "v1_lock_file")
load("@rules_jvm_external//private/rules:v2_lock_file.bzl", "v2_lock_file")

_DEFAULT_REPOSITORIES = [
    "https://repo1.maven.org/maven2",
    "https://s01.oss.sonatype.org/content/repositories/releases",
]

_DEFAULT_SETTINGS = struct(
    repo_name = "chisel_maven",
    chisel_version = "7.2.0",
    scala_version = "2.13.17",
    firtool_resolver_version = "2.0.1",
    scalatest_version = "3.2.19",
    repositories = _DEFAULT_REPOSITORIES,
    fetch_sources = True,
    lock_file = None,
)

def _scala_short(scala_version):
    parts = scala_version.split(".")
    if len(parts) < 2:
        fail("scala_version must be MAJOR.MINOR.PATCH, got '{}'".format(scala_version))
    return "{}.{}".format(parts[0], parts[1])

def _maven_target(group, artifact):
    return "{}_{}".format(group, artifact).replace(".", "_").replace("-", "_")

def _chisel_alias_repo_impl(repository_ctx):
    scala_short = _scala_short(repository_ctx.attr.scala_version)

    chisel_target = _maven_target("org.chipsalliance", "chisel_{}".format(scala_short))
    firtool_resolver_target = _maven_target("org.chipsalliance", "firtool-resolver_{}".format(scala_short))
    chisel_plugin_target = _maven_target("org.chipsalliance", "chisel-plugin_{}".format(repository_ctx.attr.scala_version))
    scalatest_target = _maven_target("org.scalatest", "scalatest_{}".format(scala_short))

    repository_ctx.file(
        "BUILD.bazel",
        content = """package(default_visibility = ["//visibility:public"])

alias(
    name = "chisel",
    actual = "@{deps_repo}//:{chisel_target}",
)

alias(
    name = "firtool_resolver",
    actual = "@{deps_repo}//:{firtool_resolver_target}",
)

alias(
    name = "chisel_plugin",
    actual = "@{deps_repo}//:{chisel_plugin_target}",
)

alias(
    name = "scalatest",
    actual = "@{deps_repo}//:{scalatest_target}",
)

alias(
    name = "pin",
    actual = "@{pin_repo}//:pin",
)

""".format(
            deps_repo = repository_ctx.attr.deps_repo_name,
            pin_repo = repository_ctx.attr.pin_repo_name,
            chisel_target = chisel_target,
            firtool_resolver_target = firtool_resolver_target,
            chisel_plugin_target = chisel_plugin_target,
            scalatest_target = scalatest_target,
        ),
    )

_chisel_alias_repo = repository_rule(
    implementation = _chisel_alias_repo_impl,
    attrs = {
        "deps_repo_name": attr.string(mandatory = True),
        "pin_repo_name": attr.string(mandatory = True),
        "scala_version": attr.string(mandatory = True),
    },
)

def _collect_settings(module_ctx):
    root_tags = []
    fallback_tags = []

    for mod in module_ctx.modules:
        tags = list(mod.tags.toolchain)
        if not tags:
            continue
        if hasattr(mod, "is_root") and mod.is_root:
            root_tags.extend(tags)
        else:
            fallback_tags.extend(tags)

    if len(root_tags) > 1:
        fail("Only one chisel.toolchain(...) tag is allowed in the root module")
    if root_tags:
        return root_tags[0]

    if len(fallback_tags) > 1:
        fail("Only one chisel.toolchain(...) tag is allowed")
    if fallback_tags:
        return fallback_tags[0]

    return _DEFAULT_SETTINGS

def _download_pinned_lockfile_artifacts(module_ctx, lock_file):
    lock_file_content = module_ctx.read(module_ctx.path(lock_file))
    if not len(lock_file_content):
        parsed_lock_file = {
            "artifacts": {},
            "dependencies": {},
            "repositories": {},
            "version": "2",
        }
    else:
        parsed_lock_file = json.decode(lock_file_content)

    if v2_lock_file.is_valid_lock_file(parsed_lock_file):
        importer = v2_lock_file
    elif v1_lock_file.is_valid_lock_file(parsed_lock_file):
        importer = v1_lock_file
    else:
        fail("Unable to read lock file: {}".format(lock_file))

    download_pinned_deps(
        mctx = module_ctx,
        artifacts = importer.get_artifacts(parsed_lock_file),
        http_files = [],
        has_m2local = importer.has_m2local(parsed_lock_file),
    )

def _chisel_extension_impl(module_ctx):
    settings = _collect_settings(module_ctx)
    scala_short = _scala_short(settings.scala_version)

    internal_repo_name = settings.repo_name + "_internal"

    artifacts = [
        "org.chipsalliance:chisel_{}:{}".format(scala_short, settings.chisel_version),
        "org.chipsalliance:chisel-plugin_{}:{}".format(settings.scala_version, settings.chisel_version),
        "org.chipsalliance:firtool-resolver_{}:{}".format(scala_short, settings.firtool_resolver_version),
        "org.scalatest:scalatest_{}:{}".format(scala_short, settings.scalatest_version),
    ]

    if settings.lock_file:
        _download_pinned_lockfile_artifacts(module_ctx, settings.lock_file)

    maven_install_args = {
        "artifacts": artifacts,
        "fetch_sources": settings.fetch_sources,
        "name": internal_repo_name,
        "repositories": settings.repositories,
    }
    if settings.lock_file:
        maven_install_args["maven_install_json"] = settings.lock_file

    maven_install(**maven_install_args)

    _chisel_alias_repo(
        name = settings.repo_name,
        deps_repo_name = internal_repo_name,
        pin_repo_name = "unpinned_" + internal_repo_name if settings.lock_file else internal_repo_name,
        scala_version = settings.scala_version,
    )

    root_is_dev = True
    for mod in module_ctx.modules:
        if hasattr(mod, "is_root") and mod.is_root:
            for tag in mod.tags.toolchain:
                if not module_ctx.is_dev_dependency(tag):
                    root_is_dev = False

    return module_ctx.extension_metadata(
        reproducible = settings.lock_file != None,
        root_module_direct_deps = [] if root_is_dev else [settings.repo_name],
        root_module_direct_dev_deps = [settings.repo_name] if root_is_dev else [],
    )

toolchain = tag_class(
    attrs = {
        "chisel_version": attr.string(default = _DEFAULT_SETTINGS.chisel_version),
        "fetch_sources": attr.bool(default = _DEFAULT_SETTINGS.fetch_sources),
        "firtool_resolver_version": attr.string(default = _DEFAULT_SETTINGS.firtool_resolver_version),
        "lock_file": attr.label(default = _DEFAULT_SETTINGS.lock_file),
        "repo_name": attr.string(default = _DEFAULT_SETTINGS.repo_name),
        "repositories": attr.string_list(default = _DEFAULT_SETTINGS.repositories),
        "scala_version": attr.string(default = _DEFAULT_SETTINGS.scala_version),
        "scalatest_version": attr.string(default = _DEFAULT_SETTINGS.scalatest_version),
    },
)

chisel = module_extension(
    implementation = _chisel_extension_impl,
    tag_classes = {"toolchain": toolchain},
)
