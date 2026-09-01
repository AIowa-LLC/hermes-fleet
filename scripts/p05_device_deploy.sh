#!/bin/bash
# P0-5 (t_755fbd27): deploy the REAL-fleet device build to Tony's iPhone and
# verify the scripted fleet is NOT in the binary.
#
# Root cause fixed here: Debug device builds previously ran the scripted
# simulator environment (fake fleet) — connect was a no-op, no socket ever
# opened, user-added gateways reported a healthy empty roster. The fix makes
# the scripted fleet compile ONLY for DEBUG && simulator, so a Debug device
# build now runs the production graph (real Keychain + live WebSocket
# transports).
#
# Gate 1 (deterministic, pre-install): the device binary must contain NO
# scripted-fleet strings. Gate 2: xcodebuild must succeed (compile proof that
# FleetSimulator compiles out of the device slice). Then install + launch.
set -euo pipefail
cd <repo-root>
DEV="<physical-device-id>"
APP_ID="com.aiowa.hermesfleet"

echo "=== regen project (xcodegen) ==="
xcodegen generate 2>&1 | tail -1

echo "=== build (Debug, physical device) ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Debug -destination "id=$DEV" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
  2>&1 | tail -3

APP_PATH=$(ls -dt ~/Library/Developer/Xcode/DerivedData/HermesFleetApp-*/Build/Products/Debug-iphoneos/HermesFleetApp.app | head -1)
echo "APP_PATH=$APP_PATH"

echo "=== GATE: device binary must NOT contain the scripted fleet ==="
FAILED=0
for BIN in "$APP_PATH/HermesFleetApp" "$APP_PATH/HermesFleetApp.debug.dylib"; do
  [ -f "$BIN" ] || continue
  for s in "Gaming 4090" "Hello from the scripted fleet" "Arch Lab" "<dev-workstation>"; do
    if strings "$BIN" | grep -qF "$s"; then
      echo "FAIL: scripted-fleet marker '$s' PRESENT in $BIN — fake fleet shipped to device"
      FAILED=1
    fi
  done
done
if [ "$FAILED" -ne 0 ]; then
  echo "GATE FAILED: refusing to install a fake-fleet device build"
  exit 1
fi
echo "GATE PASSED: no scripted-fleet markers in the device binary"

echo "=== install to iPhone ==="
xcrun devicectl device install app --device "$DEV" "$APP_PATH" 2>&1 | tail -2

echo "=== launch ==="
xcrun devicectl device process launch --device "$DEV" "$APP_ID" 2>&1 | tail -2

echo "=== done — on the phone: Gateways → (re-add or existing) → menu → Connect ==="
echo "expect: Connected badge; Roster populates with live bots from <lan-ip>:9120"
