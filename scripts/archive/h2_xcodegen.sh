#!/usr/bin/env bash
# h2_xcodegen.sh — H2: regenerate the Xcode project (new FleetCore/FleetPersistence/
# FleetNetworking/FleetUI sources + the H2 UI test target file), then build for
# the simulator. Runs via `bash scripts/h2_xcodegen.sh`.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== H2 xcodegen + build =="

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ABORT: xcodegen not found on PATH." >&2
  exit 1
fi

xcodegen generate
echo "== xcodegen done =="

DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$PWD/build/H2DerivedData"
mkdir -p build

echo "=== xcodebuild build (Debug, simulator) ==="
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -configuration Debug build \
    > /tmp/h2_build.log 2>&1; then
  echo "BUILD SUCCEEDED"
  grep -E "warning:|error:" /tmp/h2_build.log | head -20 || true
else
  echo "BUILD FAILED — tail of log:"
  grep -E "error:|failed" /tmp/h2_build.log | head -40
  exit 1
fi
