#!/bin/bash
# Causal experiment v3 (clean): start from the failing state (HappyPath ran
# first), then simulate the CORRECT remediation — the app itself clears its
# nav on NAV_RESET=1 (what the fix should do) — by removing the plist
# (container reinstall recreated it; file manipulation is equivalent because
# cfprefsd is not caching this sim's domain on the host in this state).
set -u
UDID=hgoal-i16-UDID-redacted
APP=com.aiowa.hermesfleet
OUT=/tmp/hgoal/i16-evidence/local/causal
mkdir -p "$OUT"
cd /tmp/hgoal/i16-evidence

# 1. Recreate the failing precondition exactly: HappyPath (persists render-box
#    bot detail nav), then confirm the key is present.
echo "=== step 1: HappyPath to seed persisted nav ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/C1Ui \
  -skipMacroValidation -resultBundlePath "$OUT/seed_happypath.xcresult" \
  -only-testing:HermesFleetAppUITests/HermesFleetHappyPathUITests \
  test > "$OUT/seed_happypath.log" 2>&1
echo "happypath rc=$? | $(grep -E 'Executed .* tests' "$OUT/seed_happypath.log" | tail -1)"

CONT=$(xcrun simctl get_app_container "$UDID" "$APP" data)
PLIST="$CONT/Library/Preferences/com.aiowa.hermesfleet.plist"
echo "nav key present before: $(plutil -convert xml1 -o - "$PLIST" 2>/dev/null | grep -c fleet.navigation.v1)"

# 2. Delete the ENTIRE prefs file with the app terminated, then relaunch-test
#    the two failing H1 tests (they set LOCK_RESET but NOT NAV_RESET).
echo "=== step 2: wipe app prefs (simulated NAV_RESET fix), rerun failing tests ==="
xcrun simctl terminate "$UDID" "$APP" 2>/dev/null
sleep 2
rm -f "$PLIST"
echo "nav key present after rm: $(plutil -convert xml1 -o - "$PLIST" 2>/dev/null | grep -c fleet.navigation.v1 || echo 0)"

xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/C1Ui \
  -skill 2>/dev/null; \
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/C1Ui \
  -skipMacroValidation -resultBundlePath "$OUT/navkey_wiped.xcresult" \
  -only-testing:HermesFleetAppUITests/H1AppLockUITests/testBiometricSuccessUnlocksToRoster \
  -only-testing:HermesFleetAppUITests/H1AppLockUITests/testLockToggleDefaultsOnAndPersistsAcrossRestart \
  test > "$OUT/navkey_wiped.log" 2>&1
rc=$?
echo "rc=$rc | $(grep -E 'Executed .* tests' "$OUT/navkey_wiped.log" | tail -1)"
grep -E "Test Case.*(passed|failed)" "$OUT/navkey_wiped.log" | sed 's/^.*] //'
