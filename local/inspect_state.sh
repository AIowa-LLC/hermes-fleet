#!/bin/bash
# i16 evidence: inspect persisted nav state (fleet.navigation.v1) in the app
# container on hgoal-i16 after a given suite, then (optionally) launch the app
# cold with the H1 biometric-success env and screenshot where it lands.
set -u
UDID=hgoal-i16-UDID-redacted
APP=com.aiowa.hermesfleet
CONT=$(xcrun simctl get_app_container "$UDID" "$APP" data 2>/dev/null)
echo "container: $CONT"
PLIST="$CONT/Library/Preferences/com.aiowa.hermesfleet.plist"
if [ -f "$PLIST" ]; then
  echo "--- defaults (nav + lock keys) ---"
  plutil -convert xml1 -o - "$PLIST" | grep -A6 "fleet.navigation.v1\|fleet.appLock" | head -60
else
  echo "no plist at $PLIST"
  ls "$CONT/Library/Preferences/" 2>/dev/null | head
fi
