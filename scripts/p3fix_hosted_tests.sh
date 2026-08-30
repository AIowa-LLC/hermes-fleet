#!/bin/bash
# t_eb5455f2: run the hosted app test suite (HermesFleetAppTests) on the
# simulator to confirm all tests are green after the changes.
set -u
cd <repo-root> || exit 1
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -derivedDataPath build/TestDerivedData \
  -only-testing:HermesFleetAppTests \
  test 2>&1 | grep -aE "Test Suite '(HermesFleetAppTests|Selected tests)'.*(passed|failed)|Executed .* tests|error:|BUILD|TEST EXECUTE" | tail -15
echo "EXIT=${PIPESTATUS[0]}"
