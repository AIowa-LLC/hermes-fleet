#!/bin/bash
# H2 (t_eb6b573d): device build + install + on-device surface-doctor tests.
# Builds Debug for Tony's iPhone (unlocked, per F1 memory), installs via
# devicectl, then runs the hosted H2SurfaceDoctorDeviceTests on device
# (unit-bundle hosting = app-profile signing, the B1 QA pattern).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/fleet_device.sh
source scripts/fleet_device.sh
DEST_ID="$(resolve_fleet_device)"
DERIVED="build/H2DeviceDerivedData"

echo "=== device: $DEST_ID ==="

echo "=== xcodegen ==="
export PATH="$HOME/homebrew/bin:$PATH"
xcodegen generate

echo "=== xcodebuild build-for-testing (Debug, device, unit scheme) ==="
xcodebuild -project HermesFleetApp.xcodeproj \
  -scheme HermesFleetAppUnitTests \
  -destination "id=$DEST_ID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  build-for-testing 2>&1 | tail -3

echo "=== on-device test: H2SurfaceDoctorDeviceTests ==="
xcodebuild -project HermesFleetApp.xcodeproj \
  -scheme HermesFleetAppUnitTests \
  -destination "id=$DEST_ID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -only-testing:HermesFleetAppTests/H2SurfaceDoctorDeviceTests \
  test-without-building 2>&1 | tee /tmp/h2_device_test.log | \
  grep -E "Test Suite|Test Case.*(passed|failed)|Executed|error:" | tail -30

echo "=== install app for dogfood (build 26) ==="
APP="$DERIVED/Build/Products/Debug-iphoneos/HermesFleetApp.app"
xcrun devicectl device install app --device "$DEST_ID" "$APP" 2>&1 | tail -3
echo "=== done ==="
