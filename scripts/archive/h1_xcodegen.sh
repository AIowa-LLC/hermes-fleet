#!/usr/bin/env bash
# h1_xcodegen.sh — H1 (R4): regenerate the Xcode project so the new
# FleetUI lock sources + test files are picked up, then build for the
# simulator. Runs via `bash scripts/h1_xcodegen.sh`.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== H1 xcodegen + build =="

# Guard: no modified TRACKED files from another lane worker.
dirty=$(git status --porcelain | grep -E '^ ?[MADRCU]' || true)
if [ -n "$dirty" ]; then
  echo "WARN: tracked files modified/staged (H1 edits are expected here):"
  echo "$dirty"
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ABORT: xcodegen not found on PATH." >&2
  exit 1
fi

xcodegen generate
echo "== xcodegen done =="

DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$PWD/build/H1DerivedData"
mkdir -p build

echo "=== xcodebuild build (Debug, simulator) ==="
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -configuration Debug build \
    > /tmp/h1_build.log 2>&1; then
  echo "BUILD SUCCEEDED"
  grep -E "warning:|error:" /tmp/h1_build.log | head -20 || true
else
  echo "BUILD FAILED — tail of log:"
  grep -E "error:|failed" /tmp/h1_build.log | head -40
  exit 1
fi
