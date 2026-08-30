#!/bin/bash
# t_eb5455f2: rebuild the Release app for the device and install via devicectl
# if signing permits. If the phone is still locked / signing fails, document the
# exact morning steps instead.
set -u
cd <repo-root> || exit 1
DD=build/DeviceDerivedData
BUNDLE=<legacy-personal-bundle-id>
UDID=<physical-device-id>

echo "=== [1/3] build Release iphoneos ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release -destination "id=$UDID" \
  -derivedDataPath "$DD" \
  build 2>&1 | grep -aE "BUILD (SUCCEEDED|FAILED)|error:|No Account|requires a development team|provisioning" | tail -8
BUILD_RC=${PIPESTATUS[0]}

APP="$DD/Build/Products/Release-iphoneos/HermesFleetApp.app"
if [ ! -d "$APP" ]; then
  echo "  APP NOT BUILT (rc=$BUILD_RC) — signing/profile issue; document morning steps."
  exit 2
fi
echo "  built: $APP"

echo "=== [2/3] codesign verify (team + expiry sanity) ==="
codesign -dv "$APP" 2>&1 | grep -aE "Identifier|TeamIdentifier|ApplicationIdentifier" | head -5

echo "=== [3/3] install via devicectl ==="
xcrun devicectl device install app --device "$UDID" "$APP" 2>&1 | tail -8
echo "  install exit: $?"
echo "=== Done ==="
