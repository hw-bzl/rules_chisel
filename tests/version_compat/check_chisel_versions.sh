#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if command -v bazelisk >/dev/null 2>&1; then
  # Prefer bazelisk so CI/local runs honor .bazelversion deterministically.
  BAZEL_BIN="bazelisk"
elif command -v bazel >/dev/null 2>&1; then
  BAZEL_BIN="bazel"
else
  echo "ERROR: bazel/bazelisk not found in PATH" >&2
  exit 1
fi

# Keep bazelisk on the repository-pinned Bazel version even in tmp workspaces.
if [[ -f "${REPO_ROOT}/.bazelversion" ]]; then
  USE_BAZEL_VERSION="$(tr -d "[:space:]" < "${REPO_ROOT}/.bazelversion")"
  export USE_BAZEL_VERSION
fi

SCALA_VERSION="2.13.17"
# Each entry uses format: chisel_version:firtool_resolver_version[:mode]
# mode is optional and supports:
#   - normal (default): use_extension(..., dev_dependency = False)
#   - dev: use_extension(..., dev_dependency = True)
if [[ $# -gt 0 ]]; then
  CASES=("$@")
else
  CASES=(
    "7.2.0:2.0.1:normal"
    "7.2.0:2.0.1:dev"
    "7.8.0:2.0.1"
  )
fi

TMP_ROOT="$(mktemp -d -t rules-chisel-compat-XXXXXX)"
cleanup() {
  set +e
  chmod -R u+w "${TMP_ROOT}" >/dev/null 2>&1 || true
  rm -rf "${TMP_ROOT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cat > "${TMP_ROOT}/WORKSPACE.bazel" <<'WS'
# Bzlmod-only compatibility tests. This file intentionally stays empty.
WS

run_case() {
  local chisel_version="$1"
  local firtool_version="$2"
  local mode="${3:-normal}"
  local extension_dev_flag=""
  if [[ "${mode}" == "dev" ]]; then
    extension_dev_flag=", dev_dependency = True"
  fi
  local case_name="chisel_${chisel_version//./_}_${mode}"
  local ws="${TMP_ROOT}/${case_name}"
  local out_root="${TMP_ROOT}/output_root"

  mkdir -p "${ws}"

  cat > "${ws}/MODULE.bazel" <<MODULE
module(name = "${case_name}")

bazel_dep(name = "rules_chisel", version = "0.3.0")
local_path_override(
    module_name = "rules_chisel",
    path = "${REPO_ROOT}",
)

bazel_dep(name = "rules_scala", version = "7.1.5")
scala_config = use_extension("@rules_scala//scala/extensions:config.bzl", "scala_config")
scala_config.settings(scala_version = "${SCALA_VERSION}")

scala_deps = use_extension("@rules_scala//scala/extensions:deps.bzl", "scala_deps")
scala_deps.scala()

chisel = use_extension("@rules_chisel//chisel:extensions.bzl", "chisel"${extension_dev_flag})
chisel.toolchain(
    chisel_version = "${chisel_version}",
    scala_version = "${SCALA_VERSION}",
    firtool_resolver_version = "${firtool_version}",
)
use_repo(chisel, "chisel_maven")
MODULE

  cat > "${ws}/BUILD.bazel" <<'BUILD'
load("@rules_chisel//chisel:defs.bzl", "chisel_binary", "chisel_library")

chisel_library(
    name = "compat_lib",
    srcs = ["Compat.scala"],
)

chisel_binary(
    name = "compat_bin",
    srcs = ["Main.scala"],
    deps = [":compat_lib"],
    main_class = "compat.Main",
)
BUILD

  cat > "${ws}/Compat.scala" <<'SCALA'
package compat

import chisel3._

class CompatAdder extends Module {
  val io = IO(new Bundle {
    val a = Input(UInt(8.W))
    val b = Input(UInt(8.W))
    val y = Output(UInt(8.W))
  })

  io.y := io.a + io.b
}
SCALA

  cat > "${ws}/Main.scala" <<'SCALA'
package compat

object Main extends App {
  println(classOf[CompatAdder].getName)
}
SCALA

  echo "==> [compat] Building with Chisel ${chisel_version} (firtool-resolver ${firtool_version}, mode=${mode})"
  (
    cd "${ws}"
    "${BAZEL_BIN}" \
      --batch \
      --nosystem_rc \
      --nohome_rc \
      --noworkspace_rc \
      --output_user_root="${out_root}" \
      build //:compat_lib //:compat_bin \
      --enable_bzlmod \
      --repository_cache="${TMP_ROOT}/repo_cache" \
      --disk_cache="${TMP_ROOT}/disk_cache" \
      --lockfile_mode=off \
      --announce_rc \
      --color=no \
      --curses=no \
      --show_timestamps \
      --verbose_failures
  )
}

for entry in "${CASES[@]}"; do
  IFS=":" read -r chisel_version firtool_version mode <<<"${entry}"
  run_case "${chisel_version}" "${firtool_version}" "${mode:-normal}"
done

echo "==> Version compatibility checks passed"
