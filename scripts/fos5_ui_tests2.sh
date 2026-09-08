#!/bin/bash
# FOS-5 second-wave regression suites (Chats/roster surfaces) + full hosted
# units re-run. Serial xcodebuilds only (kAX rule).
set -euo pipefail
cd /tmp/hermes-fleet-active
DEST='platform=iOS Simulator,id=393F1335-2DB1-48BD-96B9-A38B1EA488A4'
CLASSES=(
  FOS3FourRootShellUITests
  FOS4TruthfulHomeUITests
  P0_7SessionStateMachineUITests
  SecondGenerationUITests
  U3TabNavigationUITests
  HermesFleetHappyPathUITests
)
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" ENABLE_TESTABILITY=YES \
  -only-testing:HermesFleetAppTests test > /tmp/fos5_units2.log 2>&1 \
  && echo "UNITS PASS: $(grep -cE 'Test Case.*passed' /tmp/fos5_units2.log)" \
  || { echo "UNITS FAIL"; grep -E "error:|Failing" /tmp/fos5_units2.log | head; exit 1; }
for cls in "${CLASSES[@]}"; do
  echo "=== $cls ==="
  xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" ENABLE_TESTABILITY=YES \
    -only-testing:HermesFleetAppUITests/$cls test > "/tmp/fos5_ui2_${cls}.log" 2>&1 \
    && echo "$cls PASS" || { echo "$cls FAIL"; grep -E "error:|Failing|Assertion" "/tmp/fos5_ui2_${cls}.log" | head -20; exit 1; }
done
echo ALL_PASS
