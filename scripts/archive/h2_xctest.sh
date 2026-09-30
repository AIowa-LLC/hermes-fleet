#!/usr/bin/env bash
# h2_xctest.sh — H2: run the hosted unit suite (HermesFleetAppTests) on the
# simulator — includes ModuleBoundaryTests (M0 guard: FleetUI must stay free of
# FleetNetworking imports) and the new health-seam boundary + AppEnvironment
# health-wiring tests. Runs via `bash scripts/h2_xctest.sh`.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "ABORT: not on main (on '$BRANCH')." >&2
  exit 2
fi

DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/H2DerivedData"

echo "=== xcodebuild: HermesFleetAppTests (hosted unit) ==="
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:HermesFleetAppTests test \
    > /tmp/h2_xctest.log 2>&1; then
  echo "UNIT TESTS SUCCEEDED"
  grep -E "Test Suite '.*' (passed|failed)|Executed .* tests" /tmp/h2_xctest.log | tail -12
else
  echo "UNIT TESTS FAILED — tail of log:"
  grep -E "error:|failed|Executed" /tmp/h2_xctest.log | tail -30
  exit 1
fi

echo "--- ModuleBoundaryTests summary ---"
grep -E "Test Case.*ModuleBoundaryTests" /tmp/h2_xctest.log | tail -20
echo "--- ConnectionHealth / AppEnvironment health tests ---"
grep -E "Test Case.*(ConnectionHealth|Health)" /tmp/h2_xctest.log | tail -20
