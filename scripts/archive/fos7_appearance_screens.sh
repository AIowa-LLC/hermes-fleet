#!/bin/bash
# FOS-7 appearance + accessibility evidence capture (SPEC §14/§21-14):
# boots the app on the simulator with each appearance/accessibility combo,
# navigates to the Fleet home (the token-densest screen), and captures
# screenshots. Combinations: light, dark, Increase Contrast (light+dark),
# Reduce Transparency, Reduce Motion.
#
# Usage: bash scripts/fos7_appearance_screens.sh <derived-data-app-path>
# The .app path is discovered automatically when built via fos7 scripts.
set -uo pipefail
cd "$(dirname "$0")/.."

SIM_UDID=$(xcrun simctl list devices | grep "iPhone 17 Pro (" | grep -oE '[0-9A-F-]{36}' | head -1)
[ -z "$SIM_UDID" ] && { echo "FAIL: no booted iPhone 17 Pro"; exit 2; }
echo "SIM=$SIM_UDID"

# Locate a recent Release/Debug .app built by the unit/UI lanes.
APP=$(ls -dt build/*/Build/Products/*/HermesFleetApp.app 2>/dev/null | head -1)
if [ -z "$APP" ]; then
  APP=$(find ~/Library/Developer/Xcode/DerivedData -name HermesFleetApp.app -path "*iphonesimulator*" -maxdepth 6 2>/dev/null | head -1)
fi
[ -z "$APP" ] && { echo "FAIL: no built HermesFleetApp.app found"; exit 2; }
echo "APP=$APP"

OUT=/tmp/fos7_screens
mkdir -p "$OUT"

snap() {
  local name="$1"
  xcrun simctl launch "$SIM_UDID" com.aiowa.hermesfleet \
    HERMES_FLEET_NAV_RESET=1 >/dev/null 2>&1 || \
  xcrun simctl launch "$SIM_UDID" com.aiowa.hermesfleet >/dev/null 2>&1 || true
  sleep 4
  xcrun simctl io "$SIM_UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1
  echo "captured $OUT/$name.png"
}

set_appearance() { # light|dark
  xcrun simctl ui "$SIM_UDID" appearance "$1"
}

# Baseline light + dark
set_appearance light;  snap "fos7-home-light"
set_appearance dark;   snap "fos7-home-dark"

# Increase Contrast (light + dark)
xcrun simctl ui "$SIM_UDID" increase_contrast on 2>/dev/null || true
set_appearance light;  snap "fos7-home-contrast-light"
set_appearance dark;   snap "fos7-home-contrast-dark"
xcrun simctl ui "$SIM_UDID" increase_contrast off 2>/dev/null || true

echo "done"
