#!/usr/bin/env bash
# M14 Visual Identity — capture the home screen to verify the app icon renders.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

EVIDENCE="build/m14-evidence"
UDID="393F1335-2DB1-48BD-96B9-A38B1EA488A4"
BUNDLE_ID="<legacy-personal-bundle-id>"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
sleep 1
xcrun simctl io "$UDID" screenshot "$EVIDENCE/m14_homescreen_icon.png"
echo "captured: $EVIDENCE/m14_homescreen_icon.png"
