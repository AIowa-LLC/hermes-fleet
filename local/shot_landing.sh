#!/bin/bash
# Visual proof: cold-launch the app with H1 biometric-success env against the
# persisted (HappyPath) nav state; screenshot where it lands after unlock.
set -u
UDID=hgoal-i16-UDID-redacted
APP=com.aiowa.hermesfleet
OUT=/tmp/hgoal/i16-evidence/local/shots
mkdir -p "$OUT"
xcrun simctl terminate "$UDID" "$APP" 2>/dev/null
sleep 1
SIMCTL_CHILD_HERMES_FLEET_APP_LOCK=enabled \
SIMCTL_CHILD_HERMES_FLEET_LOCK_AUTH=success \
xcrun simctl launch "$UDID" "$APP"
sleep 8
xcrun simctl io "$UDID" screenshot "$OUT/post-unlock-persisted-nav.png"
echo "saved $OUT/post-unlock-persisted-nav.png"
# AX dump of what's on screen
xcrun simctl spawn "$UDID" log show --last 30s --predicate 'process == "HermesFleet"' --style compact 2>/dev/null | tail -5
xcrun simctl terminate "$UDID" "$APP" 2>/dev/null
echo done
