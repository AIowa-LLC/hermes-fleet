#!/usr/bin/env bash
# M14 Visual Identity — capture the home screen to verify the app icon renders.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

EVIDENCE="build/m14-evidence"
UDID="${HERMES_FLEET_SIM_ID:-}"
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-F-]{36}' | head -1)
fi
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | grep -oE '[0-9A-F-]{36}')
fi
if [ -z "$UDID" ]; then
  echo "FAIL: no booted/available iPhone simulator and no HERMES_FLEET_SIM_ID." >&2
  exit 2
fi
BUNDLE_ID="com.aiowa.hermesfleet"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
sleep 1
xcrun simctl io "$UDID" screenshot "$EVIDENCE/m14_homescreen_icon.png"
echo "captured: $EVIDENCE/m14_homescreen_icon.png"
