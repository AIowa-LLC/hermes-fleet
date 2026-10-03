#!/bin/bash
# U3 Conversation screen — streaming, replay, reconnect UX — full validation.
# Evidence: module boundary (0 FleetNetworking imports in FleetUI), package
# suites (Core/Networking/Security/Persistence), xcodegen + xcodebuild
# build/test on the iOS Simulator (ConversationViewModel scripted tests +
# ConversationFixtureLoopTests in-process full loop + ModuleBoundary seam
# tests), secrets scan, git state.
# Run with: bash scripts/u3_validate.sh
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

# --- 2. FleetCore build + tests ---------------------------------------------
note "FleetCore build + tests"
if (cd Packages/FleetCore && swift build) >/tmp/u3_core_build.log 2>&1; then
  ok "FleetCore builds"
else
  bad "FleetCore build failed"; tail -5 /tmp/u3_core_build.log
fi
CORE_OUT=$(cd Packages/FleetCore && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $CORE_OUT"
if echo "$CORE_OUT" | grep -q ', with 0 failures'; then
  ok "FleetCore tests green: $CORE_OUT"
else
  bad "FleetCore tests NOT green: $CORE_OUT"
fi

# --- 3. FleetNetworking build + tests ---------------------------------------
note "FleetNetworking build + tests"
if (cd Packages/FleetNetworking && swift build) >/tmp/u3_net_build.log 2>&1; then
  ok "FleetNetworking builds"
else
  bad "FleetNetworking build failed"; tail -8 /tmp/u3_net_build.log
fi
NET_OUT=$(cd Packages/FleetNetworking && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $NET_OUT"
if echo "$NET_OUT" | grep -q ', with 0 failures'; then
  ok "FleetNetworking tests green: $NET_OUT"
else
  bad "FleetNetworking tests NOT green: $NET_OUT"
fi

# --- 4. FleetSecurity + FleetPersistence build/tests -------------------------
note "FleetSecurity build + tests"
if (cd Packages/FleetSecurity && swift build) >/tmp/u3_sec_build.log 2>&1; then
  ok "FleetSecurity builds"
else
  bad "FleetSecurity build failed"; tail -5 /tmp/u3_sec_build.log
fi
SEC_OUT=$(cd Packages/FleetSecurity && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $SEC_OUT"
if echo "$SEC_OUT" | grep -q ', with 0 failures'; then
  ok "FleetSecurity tests green: $SEC_OUT"
else
  bad "FleetSecurity tests NOT green: $SEC_OUT"
fi

note "FleetPersistence build + tests"
if (cd Packages/FleetPersistence && swift build) >/tmp/u3_pers_build.log 2>&1; then
  ok "FleetPersistence builds"
else
  bad "FleetPersistence build failed"; tail -5 /tmp/u3_pers_build.log
fi
PERS_OUT=$(cd Packages/FleetPersistence && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $PERS_OUT"
if echo "$PERS_OUT" | grep -q ', with 0 failures'; then
  ok "FleetPersistence tests green: $PERS_OUT"
else
  bad "FleetPersistence tests NOT green: $PERS_OUT"
fi

# --- 5. xcodegen + xcodebuild build/test (iOS Simulator, app-level) ----------
note "xcodegen + xcodebuild build/test (iOS Simulator)"
if xcodegen generate >/tmp/u3_xcodegen.log 2>&1 && grep -q '3JS22HX92T' HermesFleetApp.xcodeproj/project.pbxproj; then
  ok "xcodegen regenerated; team 3JS22HX92T present"
else
  bad "xcodegen / team missing"; tail -5 /tmp/u3_xcodegen.log
fi
DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataU3"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" build >/tmp/u3_xcbuild.log 2>&1; then
  ok "xcodebuild BUILD SUCCEEDED (iOS Simulator)"
else
  bad "xcodebuild build FAILED"; tail -25 /tmp/u3_xcbuild.log
fi
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" test >/tmp/u3_xctest.log 2>&1; then
  TESTLINE=$(grep -E 'Test Suite.*(passed|failed)' /tmp/u3_xctest.log | tail -1)
  ok "xcodebuild TEST SUCCEEDED — $TESTLINE"
  # Report the Conversation suites explicitly.
  echo "  Conversation suites:"
  grep -E 'Test Suite .(ConversationViewModelTests|ConversationFixtureLoopTests|ModuleBoundaryTests). (passed|failed)' /tmp/u3_xctest.log || true
else
  bad "xcodebuild test FAILED"; grep -E 'error:|failed|Test Suite' /tmp/u3_xctest.log | tail -20
fi

# --- 6. Secrets scan (U3 sources) --------------------------------------------
note "Secrets scan (U3 sources)"
SCAN_FILES=$(find Packages/FleetUI/Sources HermesFleetApp HermesFleetAppTests Packages/FleetCore/Sources/FleetCore Packages/FleetNetworking/Sources/FleetNetworking -name '*.swift' 2>/dev/null)
HITS=$(grep -nE '"(sk-|ghp_|gho_|[A-Za-z0-9_-]{20,}token|secret-value|boundary-fixture|top-secret|loop-secret|super-secret)' $SCAN_FILES 2>/dev/null | grep -viE '// |rawValue|placeholder|localizedDescription|sessionToken: nil|boundary-fixture|top-secret-in-app|app-secret-ticket-value|app-loop-secret|secret-ticket-xyz|loop-token-abc|fixture-token|fixture-ticket' || true)
if [ -n "$HITS" ]; then
  bad "possible secret-like literal found in U3 sources:"
  echo "$HITS" | head -10
else
  ok "no hardcoded secret-like literals in U3 sources"
fi

# --- 7. Git state ------------------------------------------------------------
note "Git state"
echo "  branch: $(git rev-parse --abbrev-ref HEAD)"
echo "  changed files:"
git diff --name-status

# --- Summary -----------------------------------------------------------------
printf '\n=====================================\n'
printf 'U3 validate: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
