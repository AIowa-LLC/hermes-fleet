#!/bin/bash
# S3 (B2) — incremental: xcodegen + xcodebuild BUILD of the app (+ unit test
# bundle) so FleetUI/FleetCore wiring compiles before the full validate run.
# Run with: bash scripts/s3_build_app.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"

echo "=== xcodegen ==="
if xcodegen generate >/tmp/s3_xcodegen.log 2>&1; then
  echo "xcodegen OK"
else
  echo "xcodegen FAILED"; tail -20 /tmp/s3_xcodegen.log; exit 1
fi

DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataS3"

echo "=== xcodebuild build (iOS Simulator) ==="
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" build >/tmp/s3_xcbuild.log 2>&1; then
  echo "BUILD SUCCEEDED"
else
  echo "BUILD FAILED"; grep -E "error:" /tmp/s3_xcbuild.log | head -40; exit 1
fi
