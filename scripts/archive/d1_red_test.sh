#!/bin/bash
# D1 regression RED check: run the two new regression tests against the
# PRE-FIX code. They must FAIL (reproducing the M13 HOLD race) before the fix.
set -u
cd "$(dirname "$0")/.."
cd Packages/FleetNetworking

FILTER="testSocketDeathDuringHandshake"
echo "=== RED run: expect FAILURES on pre-fix code ==="
swift test --filter "$FILTER" 2>&1 | tee /tmp/d1_red_test.log | grep -E "Test Suite|Test Case|error:|failed|passed" | tail -40
echo "=== exit summary ==="
grep -E "Executed .* tests" /tmp/d1_red_test.log | tail -2
