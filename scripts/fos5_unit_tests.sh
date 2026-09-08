#!/bin/bash
# FOS-5 (t_41672ceb) local validation: hosted unit tests (full bundle) on
# the booted iPhone 17 Pro simulator. Single xcodebuild only (kAX rule).
set -euo pipefail
cd /tmp/hermes-fleet-active
exec xcodebuild \
  -project HermesFleetApp.xcodeproj \
  -scheme HermesFleetApp \
  -destination 'platform=iOS Simulator,id=393F1335-2DB1-48BD-96B9-A38B1EA488A4' \
  -only-testing:HermesFleetAppTests \
  ENABLE_TESTABILITY=YES \
  test 2>&1
