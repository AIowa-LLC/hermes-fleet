#!/bin/bash
# FOS-5: re-run just HappyPath after the header-route assertion update.
set -euo pipefail
cd /tmp/hermes-fleet-active
DEST='platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "$DEST" ENABLE_TESTABILITY=YES \
  -only-testing:HermesFleetAppUITests/HermesFleetHappyPathUITests test > /tmp/fos5_ui2_HermesFleetHappyPathUITests.log 2>&1 \
  && echo "HappyPath PASS" || { echo "HappyPath FAIL"; grep -E "error:|Failing|Assertion" /tmp/fos5_ui2_HermesFleetHappyPathUITests.log | head -20; exit 1; }
