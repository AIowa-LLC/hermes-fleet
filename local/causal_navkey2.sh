#!/bin/bash
# Causal experiment v2: delete the persisted nav key through cfprefcd
# (simctl spawn defaults delete), verify gone, then rerun the two failing tests.
set -u
UDID=hgoal-i16-UDID-redacted
APP=com.aiowa.hermesfleet
OUT=/tmp/hgoal/i16-evidence/local/causal
mkdir -p "$OUT"
cd /tmp/hgoal/i16-evidence
xcrun simctl terminate "$UDID" "$APP" 2>/dev/null
sleep 2
echo "--- delete via defaults (cfprefcd) ---"
xcrun simctl spawn "$UDID" defaults delete "$APP" fleet.navigation.v1
echo "--- readback ---"
xcrun simctl spawn "$UDID" defaults read "$APP" 2>/dev/null | grep -c "fleet.navigation.v1" || echo "KEY GONE"

xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/C1Ui \
  -skipMacroValidation -resultBundlePath "$OUT/navkey_removed_v2.xcresult" \
  -only-testing:HermesFleetAppUITests/H1AppLockUITests/testBiometricSuccessUnlocksToRoster \
  -only-testing:HermesFleetAppUITests/H1AppLockUITests/testLockToggleDefaultsOnAndPersistsAcrossRestart \
  test > "$OUT/navkey_removed_v2.log" 2>&1
rc=$?
echo "rc=$rc | $(grep -E 'Executed .* tests' "$OUT/navkey_removed_v2.log" | tail -1)"
grep -E "Test Case.*(passed|failed)" "$OUT/navkey_removed_v2.log" | sed 's/^.*] //'
