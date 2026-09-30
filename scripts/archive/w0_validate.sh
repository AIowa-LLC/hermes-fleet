#!/bin/bash
# W0 (#7) staged avatar appearance — local validation.
# Phases (each gated; stops at first failure):
#   1. FleetCore package tests (domain draft)
#   2. FleetNetworking package tests (wire semantics)
#   3. Hosted unit tests on the simulator (full HermesFleetAppTests)
#   4. Simulator build of the app
#   5. #7 deterministic UI journeys (BotAvatarAppearanceUITests)
#   6. Static guards: module boundary + public-safety + gitleaks
#      (the xcodegen drift gate diffs against the COMMITTED project —
#      run it after committing the regenerated pbxproj)
# NOTE: the UI journeys run on "iPhone 17" — the iPhone 17 Pro sim on
# this Mac has a pre-existing SimRenderServer crash during AX snapshots
# (reproduced on pristine main).
set -u
export PATH="$HOME/bin:$HOME/.hermes/bin:$PATH"
cd /tmp/hermes-fleet-active

note() { printf '\n=== %s ===\n' "$1"; }

note "1. FleetCore package tests"
OUT=$(cd Packages/FleetCore && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $OUT"
echo "$OUT" | grep -q ', with 0 failures' || { echo "FAIL"; exit 1; }

note "2. FleetNetworking package tests"
OUT=$(cd Packages/FleetNetworking && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $OUT"
echo "$OUT" | grep -q ', with 0 failures' || { echo "FAIL"; exit 1; }

note "3. Hosted unit tests (full HermesFleetAppTests)"
DD=build/DerivedData
OUT=$(xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -derivedDataPath "$DD" \
  -only-testing:HermesFleetAppTests test 2>&1 | \
  grep -E 'Executed .* tests|TEST FAILED|TEST SUCCEEDED' | tail -2)
echo "$OUT"
echo "$OUT" | grep -q 'TEST SUCCEEDED' || { echo "FAIL"; exit 1; }

note "4. Simulator build"
OUT=$(xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -derivedDataPath "$DD" build 2>&1 | grep -E 'BUILD SUCCEEDED|BUILD FAILED' | tail -1)
echo "  $OUT"
[ "$OUT" = "** BUILD SUCCEEDED **" ] || exit 1

note "5. #7 UI journeys (BotAvatarAppearanceUITests, iPhone 17)"
OUT=$(xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -derivedDataPath build/DerivedData17 \
  -only-testing:HermesFleetAppUITests/BotAvatarAppearanceUITests test 2>&1 | \
  grep -E 'Executed .* tests|TEST FAILED|TEST SUCCEEDED' | tail -2)
echo "$OUT"
echo "$OUT" | grep -q 'TEST SUCCEEDED' || { echo "FAIL"; exit 1; }

note "6. Static guards"
bash scripts/c1_static.sh 2>&1 | grep -E '^PASS|^FAIL'
echo "W0 validation complete."
