#!/usr/bin/env bash
# Regression test for commit 884773e ("make verilator runfiles resolve against
# VERILATOR_ROOT"). The launcher in chisel/defs.bzl must rewrite symlinks under
# $VERILATOR_ROOT/bin into real files so Perl's $RealBin resolves inside the
# runfiles tree (not back to the external source checkout the symlinks target).
#
# This test extracts the _VERILATOR_LAUNCHER_TEMPLATE from defs.bzl, runs it
# against a mocked runfiles layout, and asserts the post-conditions of the fix.
# It intentionally does not invoke real Chisel/Verilator so it runs in <1s.
set -euo pipefail

realpath_portable() {
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

DEFS_BZL="${TEST_SRCDIR:-}/_main/chisel/defs.bzl"
if [[ ! -f "$DEFS_BZL" ]]; then
    DEFS_BZL="$(pwd)/chisel/defs.bzl"
fi
if [[ ! -f "$DEFS_BZL" ]]; then
    echo "FAIL: cannot locate chisel/defs.bzl" >&2
    exit 1
fi

# Extract the text between the opening and closing triple quotes of
# _VERILATOR_LAUNCHER_TEMPLATE. Strip the assignment prefix on the first line
# and drop the closing """ line.
template="$(sed -n '/_VERILATOR_LAUNCHER_TEMPLATE = """/,/^"""$/p' "$DEFS_BZL" \
    | sed '1s/.*"""//; $d')"

if [[ -z "$template" ]]; then
    echo "FAIL: _VERILATOR_LAUNCHER_TEMPLATE not found in $DEFS_BZL" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake "external repo source checkout" — this is where the BCR-packaged
# verilator's perl scripts physically live, and what the runfiles-tree
# symlinks would point to.
EXT_SRC="$TMP/external_verilator_src/bin"
mkdir -p "$EXT_SRC"
cat > "$EXT_SRC/verilator_perl_stub" <<'PERL'
#!/usr/bin/env perl
# Content not executed; this test only inspects file identity.
PERL
chmod +x "$EXT_SRC/verilator_perl_stub"

# Mock runfiles layout:
#   runfiles/_main/                     (launcher cwd; main repo)
#   runfiles/verilator/bin/verilator    (bazel-built binary pointed at by {verilator_bin})
#   runfiles/verilator/bin/verilator_perl_stub  -> symlink into EXT_SRC
#   runfiles/verilator/verilator        (@verilator//:verilator top-level label)
#   runfiles/verilator/include/*        (pre-stubbed so BCR workarounds skip)
RUNFILES="$TMP/runfiles"
MAIN="$RUNFILES/_main"
VROOT="$RUNFILES/verilator"
mkdir -p "$MAIN" "$VROOT/bin" "$VROOT/include"

cat > "$VROOT/bin/verilator" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$VROOT/bin/verilator"

cat > "$VROOT/verilator" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$VROOT/verilator"

ln -s "$EXT_SRC/verilator_perl_stub" "$VROOT/bin/verilator_perl_stub"

: > "$VROOT/include/verilated.mk"
: > "$VROOT/include/verilated_config.h"
cat > "$VROOT/bin/verilator_includer" <<'PY'
import sys
PY
chmod +x "$VROOT/bin/verilator_includer"

INNER_REL="inner_test.sh"
cat > "$MAIN/$INNER_REL" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$MAIN/$INNER_REL"

# Apply Starlark .format() substitution for {verilator_bin}, {test_path}, and
# the {{...}} → {...} escapes used elsewhere in the template. python3 is a
# standard system tool; no new Bazel dep is introduced.
VBIN_REL="../verilator/bin/verilator"
launcher="$(printf '%s' "$template" | python3 -c '
import sys
tmpl = sys.stdin.read()
sys.stdout.write(tmpl.format(verilator_bin=sys.argv[1], test_path=sys.argv[2]))
' "$VBIN_REL" "$INNER_REL")"

LAUNCHER="$TMP/launcher.sh"
printf '%s' "$launcher" > "$LAUNCHER"
chmod +x "$LAUNCHER"

# Precondition: the symlink does resolve to the external source tree before the
# launcher runs. If this ever breaks, the fixture itself is wrong.
pre_real="$(realpath_portable "$VROOT/bin/verilator_perl_stub")"
expected_pre_real="$(realpath_portable "$EXT_SRC/verilator_perl_stub")"
if [[ "$pre_real" != "$expected_pre_real" ]]; then
    echo "FAIL: test fixture broken — symlink does not point at external source" >&2
    exit 1
fi

export RUNFILES_DIR="$RUNFILES"
"$LAUNCHER"

fail=0

# Assertion 1: the previously-symlinked perl script is now a real file under
# VERILATOR_ROOT/bin. Before the fix, the launcher left symlinks in place.
if [[ -L "$VROOT/bin/verilator_perl_stub" ]]; then
    echo "FAIL: $VROOT/bin/verilator_perl_stub is still a symlink" >&2
    echo "       (launcher did not replace symlinks with real files — the bug)" >&2
    fail=1
fi
if [[ ! -f "$VROOT/bin/verilator_perl_stub" ]]; then
    echo "FAIL: $VROOT/bin/verilator_perl_stub is missing after launcher setup" >&2
    fail=1
fi

# Assertion 2: realpath of the bin directory (via the perl script) resolves
# inside VERILATOR_ROOT. This is exactly what Perl's $RealBin computes. Before
# the fix it resolved back into $EXT_SRC, triggering verilator's
# "VERILATOR_ROOT is set to inconsistent path" error.
realbin_dir="$(dirname "$(realpath_portable "$VROOT/bin/verilator_perl_stub")")"
expected_realbin_dir="$(realpath_portable "$VROOT/bin")"
if [[ "$realbin_dir" != "$expected_realbin_dir" ]]; then
    echo "FAIL: \$RealBin resolves to $realbin_dir, expected $VROOT/bin" >&2
    echo "       (this reproduces the VERILATOR_ROOT inconsistent-path bug)" >&2
    fail=1
fi

# Assertion 3: verilator_bin link exists. The perl wrapper shells out to
# ./verilator_bin; without this link it cannot find the bazel-built binary.
if [[ ! -e "$VROOT/bin/verilator_bin" ]]; then
    echo "FAIL: $VROOT/bin/verilator_bin missing — perl wrapper has no binary to call" >&2
    fail=1
fi

exit "$fail"
