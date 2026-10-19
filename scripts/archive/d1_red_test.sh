#!/bin/bash
# D1 regression RED check: run the two new regression tests against the
# PRE-FIX code. They must FAIL (reproducing the M13 HOLD race) before the fix.
set -u
# Private per-run scratch (never a predictable shared /tmp name: a local
# user could pre-create or symlink it and clobber files).
SCRIPT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/hf_d1_red_test.XXXXXX") || { echo "FAIL: cannot create scratch dir" >&2; exit 2; }
trap 'rm -rf "$SCRIPT_TMP"' EXIT
cd "$(dirname "$0")/.."
cd Packages/FleetNetworking

FILTER="testSocketDeathDuringHandshake"
echo "=== RED run: expect FAILURES on pre-fix code ==="
swift test --filter "$FILTER" 2>&1 | tee $SCRIPT_TMP/d1_red_test.log | grep -E "Test Suite|Test Case|error:|failed|passed" | tail -40
echo "=== exit summary ==="
grep -E "Executed .* tests" $SCRIPT_TMP/d1_red_test.log | tail -2
