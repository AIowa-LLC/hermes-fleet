#!/bin/bash
# S3 (B2) — focused iteration: build + run ONLY the S3 cleartext-warning UI
# tests on the iOS Simulator (scripted fleet, deterministic). Faster than the
# full s3_validate.sh while iterating on the UI test itself.
# Run with: bash scripts/s3_uitest.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "ABORT: not on main (on '$BRANCH') — C1's probe branch would pollute the run."
  exit 2
fi

DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataS3"

echo "=== xcodebuild: S3 cleartext-warning UI tests ==="
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:HermesFleetAppUITests/S3CleartextWarningUITests test \
    >/tmp/s3_uitest.log 2>&1; then
  grep -E "Test Suite|Test Case.*(passed|failed)|Executed" /tmp/s3_uitest.log | tail -15
  echo "UI TESTS SUCCEEDED"
else
  grep -E "error:|failed|Test Case.*failed" /tmp/s3_uitest.log | tail -25
  echo "UI TESTS FAILED"
fi
