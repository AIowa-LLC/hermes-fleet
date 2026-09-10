#!/bin/bash
# i11-repro sentinels: S3CleartextWarning + HermesFleetHappyPath, once each
set -u
cd /tmp/hgoal/i11-repro
UDID=2D2DE77F-68B9-400F-964D-8B614DAAC35C
RESULTS=/tmp/hgoal/i11-repro/build/i11-runs
for CLASS in S3CleartextWarningUITests HermesFleetHappyPathUITests; do
  rm -rf "$RESULTS/$CLASS.xcresult"
  xcrun simctl bootstatus $UDID -b >/dev/null 2>&1
  START=$(date +%s)
  xcodebuild test \
    -project HermesFleetApp.xcodeproj \
    -scheme HermesFleetApp \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath build/C1Ui \
    -only-testing:HermesFleetAppUITests/$CLASS \
    -skipMacroValidation \
    -resultBundlePath "$RESULTS/$CLASS.xcresult" \
    > "$RESULTS/$CLASS.log" 2>&1
  EXIT=$?
  WALL=$(( $(date +%s) - START ))
  LINE=$(grep -E "Test Suite '$CLASS\.xctest'.*(passed|failed)" "$RESULTS/$CLASS.log" | tail -1)
  echo "[$CLASS] exit=$EXIT wall=${WALL}s $LINE" >> "$RESULTS/progress.log"
done
echo "SENTINELS DONE $(date '+%Y-%m-%d %H:%M:%S')" >> "$RESULTS/progress.log"
