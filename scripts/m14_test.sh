#!/usr/bin/env bash
# M14 Visual Identity — run the hosted unit-test suite on the iOS simulator.
# (FleetCore package tests run separately via `make test-core`.)
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

SCHEME="HermesFleetApp"
DD="build/M14DerivedData"
UDID="393F1335-2DB1-48BD-96B9-A38B1EA488A4"   # iPhone 17 Pro (booted)

echo "=== hosted unit tests (app + cross-module boundary) ==="
xcodebuild \
  -project HermesFleetApp.xcodeproj \
  -scheme "$SCHEME" \
  -destination "id=$UDID" \
  -derivedDataPath "$DD" \
  test 2>&1 | tee build/m14-evidence/m14_test.log | tail -30

echo "=== result summary ==="
grep -E "Test Suite|Executed .* tests|TEST (SUCCEEDED|FAILED)" build/m14-evidence/m14_test.log | tail -20
