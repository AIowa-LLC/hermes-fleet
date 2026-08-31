#!/bin/bash
# U4 independent re-verification of U3 conversation claims (streaming render,
# forced-disconnect mid-stream + reconnect replay dedupe, 4401 re-auth UX,
# cold-start cache hydration) at the current main HEAD (33e2095).
#
# Evidence produced:
#   - Module boundary: 0 FleetNetworking imports in FleetUI (M0 guard)
#   - Package suites: FleetCore / FleetNetworking / FleetSecurity / FleetPersistence
#   - xcodegen + xcodebuild build/test on the iOS Simulator, with the
#     ConversationViewModelTests / ConversationFixtureLoopTests / ModuleBoundaryTests
#     suites reported explicitly
#   - Secrets scan + git state
#
# TOOLING: script file only, run with `bash scripts/u4_verify.sh`
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
PASS=0
FAIL=0
declare -a FAILURES=()

note() { printf '\n=== %s ===\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf 'FAIL  %s\n' "$1"; }

# --- 1. MODULE BOUNDARY: FleetUI must have ZERO FleetNetworking imports -----
note "Module boundary: no 'import FleetNetworking' in FleetUI sources"
UI_SOURCES=$(find Packages/FleetUI/Sources -name '*.swift')
HITS=$(grep -nE '^\s*import\s+FleetNetworking\b' $UI_SOURCES 2>/dev/null || true)
if [ -z "$HITS" ]; then
  ok "FleetUI has 0 'import FleetNetworking' (M0 hard guard preserved)"
else
  bad "FleetUI imports FleetNetworking:"
  echo "$HITS" | head -20
fi

# --- 2. Package suites -------------------------------------------------------
run_pkg() {
  local name=$1
  local out
  note "$name build + tests"
  if (cd "Packages/$name" && swift build) >"/tmp/u4_${name}_build.log" 2>&1; then
    ok "$name builds"
  else
    bad "$name build failed"; tail -5 "/tmp/u4_${name}_build.log"
  fi
  out=$(cd "Packages/$name" && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
  echo "  $out"
  if echo "$out" | grep -q ', with 0 failures'; then
    ok "$name tests green: $out"
  else
    bad "$name tests NOT green: $out"
  fi
}
run_pkg FleetCore
run_pkg FleetNetworking
run_pkg FleetSecurity
run_pkg FleetPersistence

# --- 3. xcodegen + xcodebuild build/test (iOS Simulator) ---------------------
note "xcodegen + xcodebuild build/test (iOS Simulator)"
if xcodegen generate >/tmp/u4_xcodegen.log 2>&1 && grep -q '3JS22HX92T' HermesFleetApp.xcodeproj/project.pbxproj; then
  ok "xcodegen regenerated; team 3JS22HX92T present"
else
  bad "xcodegen / team missing"; tail -5 /tmp/u4_xcodegen.log
fi
DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataU4Verify"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" build >/tmp/u4_xcbuild.log 2>&1; then
  ok "xcodebuild BUILD SUCCEEDED (iOS Simulator)"
else
  bad "xcodebuild build FAILED"; tail -25 /tmp/u4_xcbuild.log
fi
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" test >/tmp/u4_xctest.log 2>&1; then
  TESTLINE=$(grep -E 'Test Suite.*(passed|failed)' /tmp/u4_xctest.log | tail -1)
  ok "xcodebuild TEST SUCCEEDED — $TESTLINE"
  echo "  Conversation + boundary suites:"
  grep -E 'Test Suite .(ConversationViewModelTests|ConversationFixtureLoopTests|ModuleBoundaryTests). (passed|failed)' /tmp/u4_xctest.log || true
else
  bad "xcodebuild test FAILED"; grep -E 'error:|failed|Test Suite' /tmp/u4_xctest.log | tail -25
fi

# --- 4. Explicit U3-claim assertions (map each claim to its green test) ------
note "U3 claim -> test mapping (independent re-verification)"
CLAIM_CHECKS=(
  "streaming render|testSendStreamsDeltasIncrementallyAndCompletes"
  "forced-disconnect mid-stream + reconnect replay dedupe|testFullLoopForcedDisconnectReconnectReplayDedupe"
  "replay dedupe visible in transcript (view model)|testReplayDedupeVisibleInTranscript"
  "4401 re-auth UX, no silent retry|test4401SurfacesAuthRequiredNoSilentRetry"
  "cold-start cache hydration|testColdStartHydratesFromCache"
)
for pair in "${CLAIM_CHECKS[@]}"; do
  claim="${pair%%|*}"
  testname="${pair##*|}"
  logname="${testname/()/}"
  if grep -qE "Test Case '-\\[.* $logname\\]' passed" /tmp/u4_xctest.log; then
    ok "$claim — $testname() passed"
  else
    bad "claim check missing from test log: $testname"
    grep "$logname" /tmp/u4_xctest.log | tail -3
  fi
done

# --- 5. Secrets scan ---------------------------------------------------------
note "Secrets scan (U4 sources)"
SCAN_FILES=$(find Packages/FleetUI/Sources HermesFleetApp HermesFleetAppTests Packages/FleetCore/Sources/FleetCore Packages/FleetNetworking/Sources/FleetNetworking -name '*.swift' 2>/dev/null)
HITS=$(grep -nE '"(sk-|ghp_|gho_|[A-Za-z0-9_-]{20,}token|secret-value|boundary-fixture|top-secret|loop-secret|super-secret)' $SCAN_FILES 2>/dev/null | grep -viE '// |rawValue|placeholder|localizedDescription|sessionToken: nil|boundary-fixture|top-secret-in-app|app-secret-ticket-value|app-loop-secret|secret-ticket-xyz|loop-token-abc|fixture-token|fixture-ticket' || true)
if [ -n "$HITS" ]; then
  bad "possible secret-like literal found in sources:"
  echo "$HITS" | head -10
else
  ok "no hardcoded secret-like literals in U4 sources"
fi

# --- 6. Git state ------------------------------------------------------------
note "Git state"
echo "  branch: $(git rev-parse --abbrev-ref HEAD)"
echo "  HEAD: $(git rev-parse --short HEAD)"
git diff --name-status

# --- Summary -----------------------------------------------------------------
printf '\n=====================================\n'
printf 'U4 verify: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
