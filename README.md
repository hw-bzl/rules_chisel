# rules_chisel

[![BCR](https://img.shields.io/badge/BCR-rules_chisel-green?logo=bazel)](https://registry.bazel.build/modules/rules_chisel)
[![CI](https://github.com/MrAMS/bazel_rules_chisel/actions/workflows/ci.yml/badge.svg)](https://github.com/MrAMS/bazel_rules_chisel/actions/workflows/ci.yml)

Bazel rules for Chisel projects with Bzlmod support.

This repository packages the following helpers as a BCR-friendly module:

- `chisel_binary`
- `chisel_library`
- `chisel_test`
- `verilog_single_file_library`

## Features

- One extension (`chisel.toolchain`) to fetch Chisel/ScalaTest Maven artifacts.
- Ready-to-use macro defaults via `@chisel_maven` aliases (`:chisel`, `:chisel_plugin`, etc.).
- Built-in Verilator runtime wrapper in `chisel_test` for BCR Verilator layout quirks.
- Minimal smoke tests and GitHub CI workflows.

## Installation (Bzlmod)

Add this to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_chisel", version = "0.3.0")

# rules_chisel uses rules_scala underneath.
bazel_dep(name = "rules_scala", version = "7.1.5")

# Required: configure Scala toolchain yourself.
# rules_chisel intentionally does NOT auto-register Scala toolchains.
scala_config = use_extension("@rules_scala//scala/extensions:config.bzl", "scala_config")
scala_config.settings(scala_version = "2.13.17")

scala_deps = use_extension("@rules_scala//scala/extensions:deps.bzl", "scala_deps")
scala_deps.scala()
scala_deps.scalatest()  # only needed if you use chisel_test

bazel_dep(name = "verilator", version = "5.044") # only needed if you use chisel_test

# Chisel dependencies (creates @chisel_maven)
chisel = use_extension("@rules_chisel//chisel:extensions.bzl", "chisel")
chisel.toolchain(
    chisel_version = "7.8.0",
    scala_version = "2.13.17", # should match rules_scala's scala_version
    firtool_resolver_version = "2.0.1",  # choose a known compatible resolver for your Chisel release
    lock_file = "//:maven_install.json",  # run `touch maven_install.json && REPIN=1 bazel run @chisel_maven//:pin` to generate the lock file
)
use_repo(chisel, "chisel_maven")
```

If you are authoring a reusable Bazel module (not an application root) and only need Chisel for that module's own development/tests, use `dev_dependency = True` on `use_extension(...)` so your toolchain tag does not leak to downstream consumers.


## Notes

- Scala toolchain setup is **mandatory** in your own `MODULE.bazel`. This is by design: `rules_chisel` leaves Scala version/toolchain control to users.
- `chisel_test` wraps `scala_test` and sets up a Verilator runtime environment. It expects `@verilator//:bin/verilator` and `@verilator//:verilator_includes`. If you don't use `chisel_test`, you can skip the Verilator dependency.
- Please explicitly set `firtool_resolver_version` in `chisel.toolchain(...)`. Use the Chisel Maven POM as the source of truth (for example: [`chisel_2.13-7.8.0.pom`](https://repo1.maven.org/maven2/org/chipsalliance/chisel_2.13/7.8.0/chisel_2.13-7.8.0.pom), see dependency `firtool-resolver_2.13` with `<version>2.0.1</version>`).
- To speed up dependency resolution, set `lock_file` and pin once: `touch maven_install.json && REPIN=1 bazel run @chisel_maven//:pin`.

## Usage

You can check `tests` for examples as well.

```starlark
load("@rules_chisel//chisel:defs.bzl", "chisel_binary", "chisel_library", "chisel_test")
load("@rules_chisel//verilog:defs.bzl", "verilog_single_file_library")

chisel_library(
    name = "adder_lib",
    srcs = ["Adder.scala"],
)

chisel_binary(
    name = "emit_adder",
    srcs = ["EmitAdder.scala"],
    deps = [":adder_lib"],
    main_class = "demo.EmitAdder",
)

chisel_test(
    name = "adder_test",
    srcs = ["AdderTest.scala"],
    deps = [":adder_lib"],
)

verilog_single_file_library(
    name = "merged_sv",
    srcs = [
        "foo.sv",
        "bar.v",
        "README.txt",  # ignored by rule
    ],
)
```

## Chisel Extension Options

`chisel.toolchain(...)` supports:

- `repo_name` (default: `"chisel_maven"`)
- `chisel_version` (default: `"7.2.0"`)
- `scala_version` (default: `"2.13.17"`)
- `firtool_resolver_version` (set this explicitly; check the dependency in `https://repo1.maven.org/maven2/org/chipsalliance/chisel_2.13/<chisel_version>/chisel_2.13-<chisel_version>.pom`)
- `scalatest_version` (default: `"3.2.19"`)
- `repositories` (default: Maven Central + Sonatype releases)
- `fetch_sources` (default: `True`)
- `lock_file` (default: unset, recommended: `//:maven_install.json`)

If you change `repo_name`, pass the same repo to macros via `deps_repo`:

```starlark
chisel_library(
    name = "my_lib",
    srcs = ["My.scala"],
    deps_repo = "my_chisel_repo",
)
```

## Development

Local smoke targets:

```bash
bazel build //...
bazel test //tests/smoke:verilog_concat_test
bazel test //tests/smoke:simple_adder_test --test_output=errors
tests/version_compat/check_chisel_versions.sh
```

## License

Apache 2.0.
