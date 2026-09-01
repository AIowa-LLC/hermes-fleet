#!/bin/bash
# P0-6: launch the app on the simulator with the splash forced on and a long
# hold, then capture screenshots for pixel-level letterbox analysis.
set -euo pipefail
cd <repo-root>
WS=<private-kanban-path>/boards/hermes-fleet-ios/workspaces/t_9df93c29
SIM="iPhone 17 Pro Max"
BUNDLE=com.aiowa.hermesfleet
APP=build/P06DerivedData/Build/Products/Debug-iphonesimulator/HermesFleetApp.app

xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true
xcrun simctl install "$SIM" "$APP"
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
sleep 1
SIMCTL_CHILD_HERMES_FLEET_SPLASH=on \
SIMCTL_CHILD_HERMES_FLEET_SPLASH_HOLD=6.0 \
  xcrun simctl launch "$SIM" "$BUNDLE"
sleep 2.0
xcrun simctl io "$SIM" screenshot "$WS/p06_splash_live.png"
echo "captured $WS/p06_splash_live.png"
python3 "$WS/p06_verify_letterbox.py" "$WS/p06_splash_live.png"
