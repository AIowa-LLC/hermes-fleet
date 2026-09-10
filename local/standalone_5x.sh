#!/bin/bash
# i16-fix: H1AppLock standalone stress — 5 consecutive runs on the lane sim
# (same xcodebuild invocation as c1_ui_matrix.sh).
set -u
OUT=/tmp/hgoal/i16-fix/local/runs
UDID=$(xcrun simctl list devices | grep "hgoal-i16" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' | head -1)
mkdir -p "$OUT"
cd /tmp/hgoal/i16-fix
for i in 1 2 3 4 5; do
  rm -rf "$OUT/standalone_h1_${i}.xcresult"
  xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/C1Ui \
    -skipMacroValidation -resultBundlePath "$OUT/standalone_h1_${i}.xcresult" \
    -only-testing:"HermesFleetAppUITests/H1AppLockUITests" test \
    > "$OUT/standalone_h1_${i}.log" 2>&1
  rc=$?
  echo "standalone H1 run $i rc=$rc | $(grep -E 'Executed .* tests' "$OUT/standalone_h1_${i}.log" | tail -1)"
done
echo "STANDALONE DONE"
