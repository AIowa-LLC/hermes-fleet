#!/bin/bash
# t_f54b722e (T2): Release-sim UI verification of the app connecting over the
# TAILNET endpoint. Builds the Release app + UI test bundle, fresh-installs on
# the booted iPhone 17 Pro sim, runs ONLY T2FixTailnetGatewayUITests, and
# exports the result summary + screenshots + app subsystem log + serve-tailnet
# frame window as evidence. No secrets printed.
set -u
REPO=<repo-root>
cd "$REPO" || exit 1

SIM="iPhone 17 Pro"
DEST="platform=iOS Simulator,name=${SIM},OS=latest"
DD=build/T2DerivedData
XCRESULT=build/t2_uitest.xcresult
E=build/t2_evidence
mkdir -p "$E" "$E/screenshots"
rm -rf "$DD" "$XCRESULT"

# Forwarders (P3-accepted pattern: the simulator app cannot reach the Mac's
# own IPs — LAN <lan-ip> or tailnet <tailnet-ip> — due to iOS
# local-network privacy; loopback IS reachable). 19120 -> tailnet surface,
# 19121 -> LAN surface, both with Host header rewrite.
FWD_PIDS=""
start_fwd() {
  local port="$1" host="$2"
  if ! nc -z -w 2 127.0.0.1 "$port" 2>/dev/null; then
    python3 scripts/t2_tcp_forward.py "$port" "$host" 9120 >> /tmp/t2_fwd_$port.log 2>&1 &
    FWD_PIDS="$FWD_PIDS $!"
    echo "  forwarder $port -> $host:9120 started (pid $!)"
  else
    echo "  forwarder $port already up"
  fi
}
start_fwd 19120 <tailnet-ip>
start_fwd 19121 <lan-ip>
trap 'for p in $FWD_PIDS; do kill "$p" 2>/dev/null || true; done' EXIT
sleep 1
nc -z -w 2 127.0.0.1 19120 && echo "  19120 UP" || { echo "  19120 DOWN"; exit 1; }
nc -z -w 2 127.0.0.1 19121 && echo "  19121 UP" || { echo "  19121 DOWN"; exit 1; }

# Boot a simulator if none is booted.
UDID=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-F-]{36}' | head -1)
if [ -z "$UDID" ]; then
  echo "no booted simulator; booting $SIM"
  UDID=$(xcrun simctl list devices available | grep -E "iPhone 17 Pro \(" | head -1 | grep -oE '[0-9A-F-]{36}')
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/tmp/t2_sim_boot.log 2>&1 || true
fi
echo "SIM_UDID=$UDID"

echo "=== [1/5] Build Release app + UI test bundle (simulator) ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release \
  -destination "$DEST" \
  -derivedDataPath "$DD" \
  -only-testing:HermesFleetAppUITests/T2FixTailnetGatewayUITests \
  build-for-testing 2>&1 | tee /tmp/t2_build.log | tail -6
if [ "${PIPESTATUS[0]}" -ne 0 ]; then echo "BUILD FAILED"; tail -30 /tmp/t2_build.log; exit 1; fi

echo "=== [2/5] Fresh-install app on booted sim (empty registry) ==="
BUNDLE=<legacy-personal-bundle-id>
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

echo "=== [3/5] serve-tailnet.log baseline ==="
BEFORE=$(wc -l < /tmp/hermes_lan_surface/serve-tailnet.log 2>/dev/null || echo 0)
echo "  lines before test: $BEFORE"

echo "=== [4/5] Run T2FixTailnetGatewayUITests (Release) ==="
set -o pipefail
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release \
  -destination "$DEST" \
  -derivedDataPath "$DD" \
  -resultBundlePath "$XCRESULT" \
  -only-testing:HermesFleetAppUITests/T2FixTailnetGatewayUITests \
  test-without-building 2>&1 | tee /tmp/t2_test.log | tail -30
RC=${PIPESTATUS[0]}

echo "=== [5/5] Export evidence ==="
xcrun xcresulttool get test-results summary --path "$XCRESULT" > "$E/uitest_result_summary.txt" 2>&1 || true
echo "  result summary -> $E/uitest_result_summary.txt"
grep -aE "Test Case .*(passed|failed)|Executed 1 test|error:" /tmp/t2_test.log | tail -6 > "$E/uitest_result.txt" 2>/dev/null || true
echo "  test result -> $E/uitest_result.txt"
# App subsystem logs (password-login / ws-ticket / conversation instrumentation).
xcrun simctl spawn "$UDID" log show --last 30m \
  --predicate 'subsystem == "<legacy-personal-bundle-id>"' \
  > "$E/app_subsystem.log" 2>/dev/null || true
echo "  app subsystem log -> $E/app_subsystem.log ($(wc -l < "$E/app_subsystem.log") lines)"
# Serve-tailnet frame window (before/after + turn frames) as evidence.
AFTER=$(wc -l < /tmp/hermes_lan_surface/serve-tailnet.log 2>/dev/null || echo 0)
echo "  serve-tailnet.log: before=$BEFORE after=$AFTER"
tail -n 40 /tmp/hermes_lan_surface/serve-tailnet.log 2>/dev/null \
  | grep -aE "session\.|message\.|prompt|gateway\.ready|sessions\.changed" \
  > "$E/serve-tailnet-uitest-window.txt" 2>/dev/null || true
echo "  serve-log ui-test window -> $E/serve-tailnet-uitest-window.txt ($(wc -l < "$E/serve-tailnet-uitest-window.txt") lines)"
# Pull screenshots out of the xcresult for vision verification.
xcrun xcresulttool export attachments --path "$XCRESULT" --output-path "$E/screenshots" 2>/dev/null \
  && echo "  screenshots -> $E/screenshots/" && ls -la "$E/screenshots/" | head -20 || echo "  (no attachments exported)"
echo "  test exit code: $RC"
exit $RC
