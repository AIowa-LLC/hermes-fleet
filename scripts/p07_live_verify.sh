#!/bin/bash
# t_8a7f3dce (P0-7): LIVE tailnet verification of the two dogfood defects:
#   (1) open EXISTING session -> send -> reply streams; pop -> RE-ENTER ->
#       send again -> reply streams; no "connect() from open" anywhere;
#   (2) New Session affordance -> session.create -> usable (reply streams)
#       and appears in the sessions list after popping back.
#
# Mirrors scripts/t2_uitest_run.sh (P3-accepted loopback forwarder pattern;
# the sim cannot reach the Mac's own tailnet IP due to iOS local-network
# privacy, loopback IS reachable): 19120 -> <tailnet-ip>:9120.
#
# Builds the Release app + UI bundle, fresh-installs on the booted sim,
# runs ONLY P0_7LiveTailnetUITests, exports evidence (summary, screenshots,
# app subsystem log, serve-tailnet frame window). No secrets printed.
# Tooling: script file run via `bash scripts/p07_live_verify.sh`.
set -u
REPO=<repo-root>
cd "$REPO" || exit 1

SIM="iPhone 17 Pro"
DEST="platform=iOS Simulator,name=${SIM},OS=latest"
DD=build/P07DerivedData
XCRESULT=build/p07_live_uitest.xcresult
E=build/p07_evidence
mkdir -p "$E" "$E/screenshots"
rm -rf "$DD" "$XCRESULT"

# --- Forwarder: 19120 -> tailnet 9120 (T2 pattern) ---------------------------
FWD_PIDS=""
start_fwd() {
  local port="$1" host="$2"
  if ! nc -z -w 2 127.0.0.1 "$port" 2>/dev/null; then
    python3 scripts/t2_tcp_forward.py "$port" "$host" 9120 >> /tmp/p07_fwd_$port.log 2>&1 &
    FWD_PIDS="$FWD_PIDS $!"
    echo "  forwarder $port -> $host:9120 started (pid $!)"
  else
    echo "  forwarder $port already up"
  fi
}
start_fwd 19120 <tailnet-ip>
trap 'for p in $FWD_PIDS; do kill "$p" 2>/dev/null || true; done' EXIT
sleep 1
nc -z -w 2 127.0.0.1 19120 && echo "  19120 UP" || { echo "  19120 DOWN"; exit 1; }

# --- Boot a simulator if none is booted --------------------------------------
UDID=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-F-]{36}' | head -1)
if [ -z "$UDID" ]; then
  echo "no booted simulator; booting $SIM"
  UDID=$(xcrun simctl list devices available | grep -E 'iPhone 17 Pro \(' | head -1 | grep -oE '[0-9A-F-]{36}')
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/tmp/p07_sim_boot.log 2>&1 || true
fi
echo "SIM_UDID=$UDID"

echo "=== [1/5] Build Release app + UI test bundle (simulator) ==="
# ENABLE_TESTABILITY=YES override: build-for-testing also builds the hosted
# HermesFleetAppTests bundle (@testable import HermesFleetApp), which cannot
# resolve the Release app module without -enable-testing. This is a
# command-line override for the verification build ONLY — the committed
# Release config (and App Store archives) is unchanged.
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release \
  -destination "$DEST" \
  -derivedDataPath "$DD" \
  ENABLE_TESTABILITY=YES \
  -only-testing:HermesFleetAppUITests/P0_7LiveTailnetUITests \
  build-for-testing 2>&1 | tee /tmp/p07_build.log | tail -4
if [ "${PIPESTATUS[0]}" -ne 0 ]; then echo "BUILD FAILED"; tail -30 /tmp/p07_build.log; exit 1; fi

echo "=== [2/5] Fresh-install app on booted sim (empty registry) ==="
BUNDLE=com.aiowa.hermesfleet
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
APP="$DD/Build/Products/Release-iphonesimulator/HermesFleetApp.app"
xcrun simctl install "$UDID" "$APP"
echo "  installed $APP"

# Pre-grant local-network consent (P3 pattern).
TCC="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/TCC/TCC.db"
if [ -f "$TCC" ]; then
  sqlite3 "$TCC" "DELETE FROM access WHERE client='$BUNDLE';" 2>/dev/null
  sqlite3 "$TCC" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags,last_modified,pid,pid_version,boot_uuid,last_reminded) VALUES ('kTCCServiceLocalNetwork','$BUNDLE',0,2,1,1,'UNUSED',0,CAST(strftime('%s','now') AS INTEGER),-1,0,'UNUSED',0);" 2>/dev/null
  sqlite3 "$TCC" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
  echo "  local-network consent pre-granted"
else
  echo "  WARN: TCC db not found"
fi

echo "=== [3/5] serve-tailnet.log baseline ==="
BEFORE=$(wc -l < /tmp/hermes_lan_surface/serve-tailnet.log 2>/dev/null || echo 0)
echo "  lines before test: $BEFORE"

echo "=== [4/5] Run P0_7LiveTailnetUITests (Release, live gateway) ==="
set -o pipefail
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release \
  -destination "$DEST" \
  -derivedDataPath "$DD" \
  -resultBundlePath "$XCRESULT" \
  -only-testing:HermesFleetAppUITests/P0_7LiveTailnetUITests \
  test-without-building 2>&1 | tee /tmp/p07_test.log | tail -30
RC=${PIPESTATUS[0]}

echo "=== [5/5] Export evidence ==="
xcrun xcresulttool get test-results summary --path "$XCRESULT" > "$E/uitest_result_summary.txt" 2>&1 || true
grep -aE "Test Case .*(passed|failed)|Executed 1 test|error:" /tmp/p07_test.log | tail -8 > "$E/uitest_result.txt" 2>/dev/null || true
cat "$E/uitest_result.txt" 2>/dev/null
xcrun simctl spawn "$UDID" log show --last 40m \
  --predicate 'subsystem == "com.aiowa.hermesfleet"' \
  > "$E/app_subsystem.log" 2>/dev/null || true
echo "  app subsystem log -> $E/app_subsystem.log ($(wc -l < "$E/app_subsystem.log") lines)"
AFTER=$(wc -l < /tmp/hermes_lan_surface/serve-tailnet.log 2>/dev/null || echo 0)
echo "  serve-tailnet.log: before=$BEFORE after=$AFTER"
tail -n 80 /tmp/hermes_lan_surface/serve-tailnet.log 2>/dev/null \
  | grep -aE "session\.|message\.|prompt|gateway\.ready|sessions\.changed|connect" \
  > "$E/serve-tailnet-uitest-window.txt" 2>/dev/null || true
echo "  serve-log window -> $E/serve-tailnet-uitest-window.txt ($(wc -l < "$E/serve-tailnet-uitest-window.txt") lines)"
xcrun xcresulttool export attachments --path "$XCRESULT" --output-path "$E/screenshots" 2>/dev/null \
  && echo "  screenshots -> $E/screenshots/" || echo "  (no attachments exported)"
echo "  test exit code: $RC"
exit $RC
