#!/usr/bin/env bash
# M14 Visual Identity — run the hosted unit-test suite on the iOS simulator.
# (FleetCore package tests run separately via `make test-core`.)
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

SCHEME="HermesFleetApp"
DD="build/M14DerivedData"
UDID="${HERMES_FLEET_SIM_ID:-}"
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-F-]{36}' | head -1)
fi
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | grep -oE '[0-9A-F-]{36}')
fi
if [ -z "$UDID" ]; then
  echo "FAIL: no booted/available iPhone simulator and no HERMES_FLEET_SIM_ID." >&2
  exit 2
fi

echo "=== hosted unit tests (app + cross-module boundary) ==="
xcodebuild \
  -project HermesFleetApp.xcodeproj \
  -scheme "$SCHEME" \
  -destination "id=$UDID" \
  -derivedDataPath "$DD" \
  test 2>&1 | tee build/m14-evidence/m14_test.log | tail -30

echo "=== result summary ==="
grep -E "Test Suite|Executed .* tests|TEST (SUCCEEDED|FAILED)" build/m14-evidence/m14_test.log | tail -20
