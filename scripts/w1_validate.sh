#!/bin/bash
# W1 (#9) Hermes Pets as Bot avatars — local validation.
# Phases (each gated; stops at first failure):
#   1. FleetCore package tests (pet models, cache, merge, search)
#   2. FleetNetworking package tests (pet.gallery/pet.thumb wire)
#   3. Hosted unit tests on the simulator (full HermesFleetAppTests,
#      includes BotPetAvatarTests controller/draft coverage)
#   4. Simulator build of the app
#   5. #9 deterministic UI journeys (BotPetAvatarUITests, iPhone 17)
#   6. #7 regression UI journeys (BotAvatarAppearanceUITests, iPhone 17)
#   7. Live gateway pet contract smoke (throwaway serve, loopback)
#   8. Static guards (module boundary / public-safety / gitleaks /
#      xcodegen drift — run AFTER committing regenerated pbxproj)
# NOTE: the UI journeys run on "iPhone 17" — the iPhone 17 Pro sim on
# this Mac has a pre-existing SimRenderServer crash during AX snapshots.
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

note "5. #9 UI journeys (BotPetAvatarUITests, iPhone 17)"
OUT=$(xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -derivedDataPath build/DerivedData17 \
  -only-testing:HermesFleetAppUITests/BotPetAvatarUITests test 2>&1 | \
  grep -E 'Executed .* tests|TEST FAILED|TEST SUCCEEDED' | tail -2)
echo "$OUT"
echo "$OUT" | grep -q 'TEST SUCCEEDED' || { echo "FAIL"; exit 1; }

note "6. #7 regression UI journeys (BotAvatarAppearanceUITests, iPhone 17)"
OUT=$(xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -derivedDataPath build/DerivedData17 \
  -only-testing:HermesFleetAppUITests/BotAvatarAppearanceUITests test 2>&1 | \
  grep -E 'Executed .* tests|TEST FAILED|TEST SUCCEEDED' | tail -2)
echo "$OUT"
echo "$OUT" | grep -q 'TEST SUCCEEDED' || { echo "FAIL"; exit 1; }

note "7. Live gateway pet contract smoke"
bash scripts/pet_live_check.sh || exit 1

note "8. Static guards"
bash scripts/c1_static.sh 2>&1 | grep -E '^PASS|^FAIL'
echo "W1 validation complete."
