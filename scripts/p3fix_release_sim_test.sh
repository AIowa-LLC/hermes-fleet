#!/bin/bash
# t_eb5455f2: Release-sim verification of the username/password fix against the
# REAL LAN gateway. Builds the Release app + UI test bundle, fresh-installs on
# the booted iPhone 17 Pro sim, runs ONLY P3FixLANGatewayUITests, and exports
# the result summary + screenshots for evidence. No secrets printed.
set -u
REPO=<repo-root>
cd "$REPO" || exit 1

SIM="iPhone 17 Pro"
DEST="platform=iOS Simulator,name=${SIM},OS=latest"
DD=build/P3FixDerivedData
XCRESULT=build/p3fix_release_sim.xcresult
rm -rf "$DD" "$XCRESULT" build/p3fix_result_summary.txt build/p3fix_screenshots
mkdir -p build/p3fix_screenshots

echo "=== [1/4] Build Release app + UI test bundle (simulator) ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release \
  -destination "$DEST" \
  -derivedDataPath "$DD" \
  -only-testing:HermesFleetAppUITests/P3FixLANGatewayUITests \
  build-for-testing 2>&1 | tail -6
if [ "${PIPESTATUS[0]}" -ne 0 ]; then echo "BUILD FAILED"; exit 1; fi

echo
echo "=== [2/4] Fresh-install app on booted sim (empty registry) ==="
BUNDLE=com.aiowa.hermesfleet
xcrun simctl uninstall "$SIM" "$BUNDLE" 2>/dev/null || true
APP="$DD/Build/Products/Release-iphonesimulator/HermesFleetApp.app"
xcrun simctl install "$SIM" "$APP"
echo "  installed $APP"

# Pre-grant the iOS Local Network permission (iOS 14+ gate black-holes the
# app's connection to the LAN gateway without it). Insert into the sim TCC db
# AFTER install (tccd wipes rows on uninstall); the row survives this session.
UDID=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices available | grep 'Booted' | grep -oE '[0-9A-F-]{36}' | head -1)
fi
echo "  booted UDID: $UDID"
TCC="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/TCC/TCC.db"
if [ -f "$TCC" ]; then
  sqlite3 "$TCC" "DELETE FROM access WHERE client='$BUNDLE';" 2>/dev/null
  sqlite3 "$TCC" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags,last_modified,pid,pid_version,boot_uuid,last_reminded) VALUES ('kTCCServiceLocalNetwork','$BUNDLE',0,2,1,1,'UNUSED',0,CAST(strftime('%s','now') AS INTEGER),-1,0,'UNUSED',0);" 2>/dev/null
  sqlite3 "$TCC" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
  echo "  local-network consent pre-granted: $(sqlite3 "$TCC" "select service||':'||auth_value from access where client='$BUNDLE';" 2>/dev/null)"
else
  echo "  WARN: TCC db not found at $TCC"
fi

echo
echo "=== [3/4] Run P3FixLANGatewayUITests (Release) ==="
set -o pipefail
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release \
  -destination "$DEST" \
  -derivedDataPath "$DD" \
  -resultBundlePath "$XCRESULT" \
  -only-testing:HermesFleetAppUITests/P3FixLANGatewayUITests \
  test-without-building 2>&1 | tee build/p3fix_test_run.log | tail -25
RC=${PIPESTATUS[0]}

echo
echo "=== [4/4] Export evidence ==="
xcrun xcresulttool get test-results summary --path "$XCRESULT" \
  > build/p3fix_result_summary.txt 2>&1 || true
echo "  result summary -> build/p3fix_result_summary.txt"
# App subsystem logs (password-login / ws-ticket instrumentation).
xcrun simctl spawn "$SIM" log show --last 10m \
  --predicate 'subsystem == "com.aiowa.hermesfleet"' \
  > build/p3fix_app_subsystem.log 2>/dev/null || true
echo "  app subsystem log -> build/p3fix_app_subsystem.log ($(wc -l < build/p3fix_app_subsystem.log) lines)"
# Pull screenshots out of the xcresult for vision verification.
xcrun xcresulttool export attachments --path "$XCRESULT" \
  --output-path build/p3fix_screenshots 2>/dev/null \
  || xcrun xcresulttool export attachments --path "$XCRESULT" --output-path build/p3fix_screenshots \
  && echo "  screenshots -> build/p3fix_screenshots/" && ls -la build/p3fix_screenshots/ | head

echo "  test exit code: $RC"
exit $RC
