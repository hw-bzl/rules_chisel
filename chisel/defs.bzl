"""Public Chisel rules."""

load("@rules_scala//scala:scala.bzl", "scala_binary", "scala_library", "scala_test")

CHISEL_SCALACOPTS = [
    "-language:reflectiveCalls",
    "-deprecation",
    "-feature",
    "-Xcheckinit",
    "-Ytasty-reader",
]

_DEFAULT_VERILATOR_DATA = [
    "@verilator//:verilator",
    "@verilator//:bin/verilator",
    "@verilator//:verilator_includes",
]

_VERILATOR_LAUNCHER_TEMPLATE = """#!/bin/bash
set -euo pipefail
cd "$RUNFILES_DIR/_main" || exit 1

_VERILATOR_BIN="{verilator_bin}"
[[ "$_VERILATOR_BIN" != /* ]] && _VERILATOR_BIN="$PWD/$_VERILATOR_BIN"
export VERILATOR_ROOT="$(dirname "$(dirname "$_VERILATOR_BIN")")"
export PATH="$(dirname "$_VERILATOR_BIN"):$PATH"

# Replace symlinks in the verilator bin directory with real copies so that
# Perl's $RealBin resolves to the runfiles directory (which has the correct
# Bazel-generated headers) instead of the external repository source tree.
for _f in "$VERILATOR_ROOT"/bin/*; do
    [[ -L "$_f" ]] || continue
    cp -L "$_f" "$_f.tmp" && mv "$_f.tmp" "$_f" && chmod +x "$_f"
done

# Link Bazel-built verilator binary so the perl wrapper can find it.
ln -sf "$VERILATOR_ROOT/verilator" "$VERILATOR_ROOT/bin/verilator_bin" 2>/dev/null || true

# BCR Verilator workarounds.
if [[ ! -f "$VERILATOR_ROOT/include/verilated.mk" && -f "$VERILATOR_ROOT/include/verilated.mk.in" ]]; then
    sed 's/@AR@/ar/g; s/@CXX@/g++/g; s/@LINK@/g++/g; s/@OBJCACHE@//g; s/@PERL@/perl/g; s/@PYTHON3@/python3/g; s/@[A-Z_]*@//g' \
        "$VERILATOR_ROOT/include/verilated.mk.in" > "$VERILATOR_ROOT/include/verilated.mk"
fi

if [[ ! -f "$VERILATOR_ROOT/include/verilated_config.h" && -f "$VERILATOR_ROOT/include/verilated_config.h.in" ]]; then
    sed 's/@PACKAGE_STRING@/Verilator/g; s/@CFG_WITH_CCWARN@/1/g; s/@CFG_WITH_LONGTESTS@/0/g; s/@[A-Z_]*@//g' \
        "$VERILATOR_ROOT/include/verilated_config.h.in" > "$VERILATOR_ROOT/include/verilated_config.h"
fi

# Generate verilator_includer if missing (must be valid Python: invoked via `python3`)
if [[ ! -f "$VERILATOR_ROOT/bin/verilator_includer" ]]; then
    cat > "$VERILATOR_ROOT/bin/verilator_includer" << 'PYTHON_EOF'
import sys
for f in sys.argv[2:]:
    print('#include "' + f + '"')
PYTHON_EOF
fi

set +e
"$RUNFILES_DIR/_main/{test_path}" "$@"
status=$?
set -e

if [[ -n "${{TEST_UNDECLARED_OUTPUTS_DIR:-}}" ]]; then
    if [[ -d "$RUNFILES_DIR/_main/build/chiselsim" ]]; then
        mkdir -p "$TEST_UNDECLARED_OUTPUTS_DIR/chiselsim"
        cp -a "$RUNFILES_DIR/_main/build/chiselsim/." "$TEST_UNDECLARED_OUTPUTS_DIR/chiselsim/" 2>/dev/null || true
    fi
fi

exit $status
"""

def _repo_label(repo, target):
    repo_name = repo[1:] if repo.startswith("@") else repo
    return "@{}//:{}".format(repo_name, target)

def _default_chisel_deps(deps_repo):
    return [
        _repo_label(deps_repo, "chisel"),
        _repo_label(deps_repo, "firtool_resolver"),
    ]

def _default_chisel_plugins(deps_repo):
    return [_repo_label(deps_repo, "chisel_plugin")]

def _default_test_deps(deps_repo):
    return [_repo_label(deps_repo, "scalatest")]

def _chisel_test_wrapper_impl(ctx):
    test_executable = ctx.attr.test[DefaultInfo].files_to_run.executable
    verilator_bin = ctx.expand_location(ctx.attr.verilator_bin, ctx.attr.data)

    launcher = ctx.actions.declare_file(ctx.label.name + "_launcher.sh")
    ctx.actions.write(
        output = launcher,
        content = _VERILATOR_LAUNCHER_TEMPLATE.format(
            verilator_bin = verilator_bin,
            test_path = test_executable.short_path,
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [test_executable] + ctx.files.data)
    runfiles = runfiles.merge(ctx.attr.test[DefaultInfo].default_runfiles)

    return [DefaultInfo(executable = launcher, runfiles = runfiles)]

_chisel_test_wrapper_test = rule(
    implementation = _chisel_test_wrapper_impl,
    test = True,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "test": attr.label(mandatory = True, executable = True, cfg = "target"),
        "verilator_bin": attr.string(default = "$(rootpath @verilator//:bin/verilator)"),
    },
)

def chisel_binary(
        name,
        srcs,
        deps = [],
        scalacopts = [],
        deps_repo = "chisel_maven",
        **kwargs):
    """Scala binary with default Chisel dependencies and plugin."""
    scala_binary(
        name = name,
        srcs = srcs,
        deps = _default_chisel_deps(deps_repo) + deps,
        plugins = _default_chisel_plugins(deps_repo),
        scalacopts = CHISEL_SCALACOPTS + scalacopts,
        **kwargs
    )

def chisel_library(
        name,
        srcs,
        deps = [],
        scalacopts = [],
        deps_repo = "chisel_maven",
        **kwargs):
    """Scala library with default Chisel dependencies and plugin."""
    scala_library(
        name = name,
        srcs = srcs,
        deps = _default_chisel_deps(deps_repo) + deps,
        plugins = _default_chisel_plugins(deps_repo),
        scalacopts = CHISEL_SCALACOPTS + scalacopts,
        **kwargs
    )

def chisel_test(
        name,
        srcs,
        deps = [],
        data = [],
        tags = [],
        scalacopts = [],
        deps_repo = "chisel_maven",
        **kwargs):
    """Runs ScalaTest-based Chisel tests with Verilator runtime setup."""
    all_data = _DEFAULT_VERILATOR_DATA + data

    scala_test(
        name = name + "_inner",
        srcs = srcs,
        deps = _default_chisel_deps(deps_repo) + _default_test_deps(deps_repo) + deps,
        data = all_data,
        plugins = _default_chisel_plugins(deps_repo),
        scalacopts = CHISEL_SCALACOPTS + scalacopts,
        testonly = True,
        tags = ["manual"] + tags,
        **kwargs
    )

    _chisel_test_wrapper_test(
        name = name,
        test = ":" + name + "_inner",
        data = all_data,
        tags = ["local"] + tags,
    )

def _only_sv(f):
    if f.extension in ["v", "sv"]:
        return f.path
    return None

def _verilog_single_file_library_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name)

    args = ctx.actions.args()
    args.add_all(ctx.files.srcs, map_each = _only_sv)

    ctx.actions.run_shell(
        arguments = [args],
        command = "cat $@ > {}".format(out.path),
        inputs = ctx.files.srcs,
        outputs = [out],
        mnemonic = "CatVerilogFiles",
    )

    return [DefaultInfo(files = depset([out]))]

verilog_single_file_library = rule(
    implementation = _verilog_single_file_library_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Verilog files to concatenate.",
            allow_files = True,
        ),
    },
)
