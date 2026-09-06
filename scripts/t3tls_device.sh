#!/bin/bash
# T3 (t_94ee6012): device build + install + binary-marker gate.
# Per sequencer: PRODUCTION environment mandate — binary-marker gate
# (scripted-fleet markers ABSENT, production markers PRESENT) BEFORE install.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/fleet_device.sh
source "$(dirname "$0")/fleet_device.sh"
# Physical device: HERMES_FLEET_DEVICE_ID override, or unambiguous single
# eligible paired iPhone via machine-readable devicectl discovery.
DEST_ID="$(resolve_fleet_device)"
APP="build/T3DeviceDerivedData/Build/Products/Debug-iphoneos/HermesFleetApp.app"

echo "=== xcodegen ==="
xcodegen generate

echo "=== xcodebuild Debug (device) ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "id=$DEST_ID" \
  -derivedDataPath build/T3DeviceDerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  build 2>&1 | tail -3

echo "=== binary-marker gate (production env) ==="
APP_BIN="$APP/HermesFleetApp"
# Debug-iphoneos builds put app code in HermesFleetApp.debug.dylib; Release
# and stub executables carry it in the main binary. Scan BOTH.
MARK_TARGETS=("$APP_BIN")
[ -f "$APP/HermesFleetApp.debug.dylib" ] && MARK_TARGETS+=("$APP/HermesFleetApp.debug.dylib")
if [ ! -f "$APP_BIN" ]; then echo "GATE FAIL: binary missing"; exit 1; fi
# Scripted-fleet markers (must be ABSENT) — the simulator-only env strings.
SCRIPTED_HITS=0
PROD_HITS=0
for T in "${MARK_TARGETS[@]}"; do
  SCRIPTED_HITS=$((SCRIPTED_HITS + $(strings -a "$T" | grep -c "scripted fleet" || true)))
  PROD_HITS=$((PROD_HITS + $(strings -a "$T" | grep -c "hermesfleet.tlspins" || true)))
done
echo "scripted markers: $SCRIPTED_HITS (want 0)"
echo "production pin-store service marker: $PROD_HITS (want >=1)"
if [ "$SCRIPTED_HITS" -ne 0 ] || [ "$PROD_HITS" -lt 1 ]; then
  echo "GATE FAIL: environment markers wrong — DO NOT INSTALL"
  exit 1
fi
echo "GATE PASS: production environment confirmed"

echo "=== devicectl install ==="
xcrun devicectl device install app --device "$DEST_ID" "$APP" 2>&1 | tail -3
echo "=== done ==="
