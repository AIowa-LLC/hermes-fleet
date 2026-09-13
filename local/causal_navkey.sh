#!/bin/bash
# Causal experiment: after the failing repro, remove ONLY the persisted
# fleet.navigation.v1 key from the app container, then rerun the two H1 tests
# that failed. If they now pass, the persisted nav state is the cause.
set -u
UDID=hgoal-i16-UDID-redacted
APP=com.aiowa.hermesfleet
OUT=/tmp/hgoal/i16-evidence/local/causal
mkdir -p "$OUT"
cd /tmp/hgoal/i16-evidence
CONT=$(xcrun simctl get_app_container "$UDID" "$APP" data)
PLIST="$CONT/Library/Preferences/com.aiowa.hermesfleet.plist"
xcrun simctl terminate "$UDID" "$APP" 2>/dev/null
sleep 2
echo "--- before ---"; plutil -convert xml1 -o - "$PLIST" | grep -c "fleet.navigation.v1"
plutil -remove fleet.navigation.v1 "$PLIST" && echo "key removed"
echo "--- after ---"; plutil -convert xml1 -o - "$PLIST" | grep -c "fleet.navigation.v1" || true

xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/C1Ui \
  -skipMacroValidation -resultBundlePath "$OUT/navkey_removed.xcresult" \
  -only-testing:HermesFleetAppUITests/H1AppLockUITests/testBiometricSuccessUnlocksToRoster \
  -only-testing:HermesFleetAppUITests/H1AppLockUITests/testLockToggleDefaultsOnAndPersistsAcrossRestart \
  test > "$OUT/navkey_removed.log" 2>&1
rc=$?
echo "rc=$rc | $(grep -E 'Executed .* tests' "$OUT/navkey_removed.log" | tail -1)"
grep -E "Test Case.*(passed|failed)" "$OUT/navkey_removed.log" | sed 's/^.*] //'
