#!/usr/bin/env bash
# h1_unit_tests.sh — H1 (R4): run the full hosted unit-test suite
# (HermesFleetAppTests) on the simulator, including the new
# AppLockControllerTests. Runs via `bash scripts/h1_unit_tests.sh`.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "ABORT: not on main (on '$BRANCH')." >&2
  exit 2
fi

DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/H1DerivedData"

echo "=== xcodebuild: HermesFleetAppTests (hosted unit) ==="
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:HermesFleetAppTests test \
    > /tmp/h1_unit.log 2>&1; then
  echo "UNIT TESTS SUCCEEDED"
  grep -E "Test Suite '.*' (passed|failed)|Executed .* tests" /tmp/h1_unit.log | tail -12
else
  echo "UNIT TESTS FAILED — tail of log:"
  grep -E "error:|failed|Executed" /tmp/h1_unit.log | tail -30
  exit 1
fi

# Summarize the AppLock controller tests specifically.
echo "--- AppLockControllerTests summary ---"
grep -E "Test Case.*AppLockControllerTests" /tmp/h1_unit.log | tail -15
