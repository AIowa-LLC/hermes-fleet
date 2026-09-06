#!/usr/bin/env bash
# h2_uitest.sh — H2: Release-sim UI verification of the Connection health
# dashboard against the LIVE LAN gateway. Builds the Release app + UI test
# bundle, fresh-installs on the booted iPhone 17 Pro sim, runs ONLY
# H2HealthDashboardUITests, and exports the result summary + screenshots.
# No secrets printed (creds are read at runtime by the test from
# /tmp/hermes_lan_surface/.cred).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

SIM="iPhone 17 Pro"
DEST="platform=iOS Simulator,name=${SIM},OS=latest"
DD=build/H2DerivedData
XCRESULT=build/h2_uitest.xcresult
E=build/h2_evidence
mkdir -p "$E" "$E/screenshots"
rm -rf "$DD" "$XCRESULT"

# Forwarder (P3-accepted pattern): the simulator app cannot reach the Mac's
# own LAN IP (HERMES_FLEET_LAN_HOST, default 127.0.0.1) due to iOS
# local-network privacy; loopback IS reachable. 19121 -> LAN surface with
# Host header rewrite.
FWD_PIDS=""
LAN_HOST="${HERMES_FLEET_LAN_HOST:?Set HERMES_FLEET_LAN_HOST to YOUR gateway LAN host — this script targets no infrastructure by default}"
if ! nc -z -w 2 127.0.0.1 19121 2>/dev/null; then
  python3 scripts/t2_tcp_forward.py 19121 "$LAN_HOST" "${HERMES_FLEET_LAN_PORT:-9120}" >> /tmp/h2_fwd_19121.log 2>&1 &
  FWD_PIDS="$FWD_PIDS $!"
  echo "  forwarder 19121 -> $LAN_HOST:${HERMES_FLEET_LAN_PORT:-9120} started (pid $!)"
else
  echo "  forwarder 19121 already up"
fi
trap 'for p in $FWD_PIDS; do kill "$p" 2>/dev/null || true; done' EXIT
sleep 1
nc -z -w 2 127.0.0.1 19121 && echo "  19121 UP" || { echo "  19121 DOWN"; exit 1; }

# Boot a simulator if none is booted.
UDID=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-F-]{36}' | head -1)
if [ -z "$UDID" ]; then
  echo "no booted simulator; booting $SIM"
  UDID=$(xcrun simctl list devices available | grep -E "iPhone 17 Pro \(" | head -1 | grep -oE '[0-9A-F-]{36}')
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/tmp/h2_sim_boot.log 2>&1 || true
fi
echo "SIM_UDID=$UDID"

echo "=== [1/5] Build Release app + UI test bundle (simulator) ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release \
  -destination "$DEST" \
  -derivedDataPath "$DD" \
  -only-testing:HermesFleetAppUITests/H2HealthDashboardUITests \
  build-for-testing 2>&1 | tee /tmp/h2_build.log | tail -6
if [ "${PIPESTATUS[0]}" -ne 0 ]; then echo "BUILD FAILED"; tail -30 /tmp/h2_build.log; exit 1; fi

echo "=== [2/5] Fresh-install app on booted sim (empty registry) ==="
BUNDLE=com.aiowa.hermesfleet
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
APP="$DD/Build/Products/Release-iphonesimulator/HermesFleetApp.app"
xcrun simctl install "$UDID" "$APP"
echo "  installed $APP"

# Pre-grant the iOS Local Network permission in the sim TCC db (P3 pattern).
TCC="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/TCC/TCC.db"
if [ -f "$TCC" ]; then
  sqlite3 "$TCC" "DELETE FROM access WHERE client='$BUNDLE';" 2>/dev/null
  sqlite3 "$TCC" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags,last_modified,pid,pid_version,boot_uuid,last_reminded) VALUES ('kTCCServiceLocalNetwork','$BUNDLE',0,2,1,1,'UNUSED',0,CAST(strftime('%s','now') AS INTEGER),-1,0,'UNUSED',0);" 2>/dev/null
  sqlite3 "$TCC" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
  echo "  local-network consent pre-granted: $(sqlite3 "$TCC" "select service||':'||auth_value from access where client='$BUNDLE';" 2>/dev/null)"
else
  echo "  WARN: TCC db not found at $TCC"
fi

echo "=== [3/5] LAN gateway reachability check ==="
LAN_PORT="${HERMES_FLEET_LAN_PORT:-9120}"
LAN_URL="http://$LAN_HOST:$LAN_PORT"
python3 - "$LAN_URL" <<'PYEOF'
import sys, urllib.request
url = sys.argv[1]
try:
    r = urllib.request.urlopen(url + "/", timeout=5)
    print(f"  gateway {url} HTTP {r.status}")
except Exception as e:
    print(f"  WARN: gateway {url} unreachable: {e}")
PYEOF

echo "=== [4/5] Run H2HealthDashboardUITests (Release) ==="
set -o pipefail
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release \
  -destination "$DEST" \
  -derivedDataPath "$DD" \
  -resultBundlePath "$XCRESULT" \
  -only-testing:HermesFleetAppUITests/H2HealthDashboardUITests \
  test-without-building 2>&1 | tee /tmp/h2_test.log | tail -30
RC=${PIPESTATUS[0]}

echo "=== [5/5] Export evidence ==="
xcrun xcresulttool get test-results summary --path "$XCRESULT" > "$E/uitest_result_summary.txt" 2>&1 || true
echo "  result summary -> $E/uitest_result_summary.txt"
grep -aE "Test Case .*(passed|failed)|Executed 1 test|error:" /tmp/h2_test.log | tail -6 > "$E/uitest_result.txt" 2>/dev/null || true
echo "  test result -> $E/uitest_result.txt"
xcrun xcresulttool export attachments --path "$XCRESULT" --output-path "$E/screenshots" 2>/dev/null \
  && echo "  screenshots -> $E/screenshots/" && ls -la "$E/screenshots/" | head -20 || echo "  (no attachments exported)"
echo "  test exit code: $RC"
exit $RC
