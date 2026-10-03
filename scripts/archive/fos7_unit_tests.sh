#!/bin/bash
# FOS-7 unit test lane — hosted unit tests (full bundle).
set -euo pipefail
cd "$(dirname "$0")/.."

DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
LOG=/tmp/fos7_units.log

xcodebuild -project HermesFleetApp.xcodeproj \
  -scheme HermesFleetApp \
  -destination "$DEST" \
  -only-testing:HermesFleetAppTests \
  -resultBundlePath /tmp/fos7_units_$(date +%s).xcresult \
  test >"$LOG" 2>&1 || {
    echo "FAIL: see $LOG"
    grep -E "error:|failed|Failing" "$LOG" | head -30
    exit 1
  }

grep -E "Test Suite 'HermesFleetAppTests'|Executed .* tests" "$LOG" | tail -4
echo "PASS (log: $LOG)"
