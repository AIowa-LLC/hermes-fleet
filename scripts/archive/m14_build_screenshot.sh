#!/usr/bin/env bash
# M14 Visual Identity — build, install, launch, and capture light/dark
# screenshots on the iOS simulator. Exit non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

SCHEME="HermesFleetApp"
BUNDLE_ID="com.aiowa.hermesfleet"
DD="build/M14DerivedData"
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

mkdir -p "$EVIDENCE"

echo "=== [1/5] xcodegen generate ==="
xcodegen generate

echo "=== [2/5] build (iOS Simulator) ==="
xcodebuild \
  -project HermesFleetApp.xcodeproj \
  -scheme "$SCHEME" \
  -destination "id=$UDID" \
  -derivedDataPath "$DD" \
  -quiet \
  build 2>&1 | tail -40

APP_PATH="$DD/Build/Products/Debug-iphonesimulator/HermesFleetApp.app"
if [ ! -d "$APP_PATH" ]; then
  echo "FATAL: app bundle not found at $APP_PATH" >&2
  exit 1
fi

echo "=== [3/5] install + launch ==="
xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"
sleep 3

echo "=== [4/5] capture dark ==="
xcrun simctl ui "$UDID" appearance dark
sleep 1
xcrun simctl io "$UDID" screenshot "$EVIDENCE/m14_empty_dark.png"

echo "=== [5/5] capture light ==="
xcrun simctl ui "$UDID" appearance light
sleep 1
xcrun simctl io "$UDID" screenshot "$EVIDENCE/m14_empty_light.png"

echo "=== done ==="
ls -la "$EVIDENCE"
