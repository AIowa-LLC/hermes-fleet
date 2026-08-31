#!/bin/bash
# D1 deterministic waitForReady classification — full validation.
# Evidence: new regression tests (RED on pre-fix, GREEN post-fix) + full
# FleetNetworking + FleetCore suites + xcodebuild build/test + secrets scan.
# Run with: bash scripts/d1_validate.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
PASS=0
FAIL=0
declare -a FAILURES=()

note() { printf '\n=== %s ===\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf 'FAIL  %s\n' "$1"; }

# --- 1. New regression tests must PASS (GREEN) on the fixed code -------------
note "D1 regression tests (GREEN on fixed code)"
REG_OUT=$(cd Packages/FleetNetworking && swift test --filter testSocketDeathDuringHandshake 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $REG_OUT"
if echo "$REG_OUT" | grep -q ', with 0 failures'; then
  ok "D1 regression tests green: $REG_OUT"
else
  bad "D1 regression tests NOT green: $REG_OUT"
fi

# --- 2. FleetCore build + tests (dependency regression) ----------------------
note "FleetCore build + tests"
if (cd Packages/FleetCore && swift build) >/tmp/d1_core_build.log 2>&1; then
  ok "FleetCore builds"
else
  bad "FleetCore build failed"; tail -5 /tmp/d1_core_build.log
fi
CORE_OUT=$(cd Packages/FleetCore && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $CORE_OUT"
if echo "$CORE_OUT" | grep -q ', with 0 failures'; then
  ok "FleetCore tests green: $CORE_OUT"
else
  bad "FleetCore tests NOT green: $CORE_OUT"
fi

# --- 3. FleetNetworking build + full test suite ------------------------------
note "FleetNetworking build + full test suite"
if (cd Packages/FleetNetworking && swift build) >/tmp/d1_net_build.log 2>&1; then
  ok "FleetNetworking builds"
else
  bad "FleetNetworking build failed"; tail -8 /tmp/d1_net_build.log
fi
NET_OUT=$(cd Packages/FleetNetworking && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $NET_OUT"
if echo "$NET_OUT" | grep -q ', with 0 failures'; then
  ok "FleetNetworking tests green: $NET_OUT"
else
  bad "FleetNetworking tests NOT green: $NET_OUT"
fi

# --- 4. FleetSecurity + FleetPersistence build/tests (regression) ------------
note "FleetSecurity build + tests"
if (cd Packages/FleetSecurity && swift build) >/tmp/d1_sec_build.log 2>&1; then
  ok "FleetSecurity builds"
else
  bad "FleetSecurity build failed"; tail -5 /tmp/d1_sec_build.log
fi
SEC_OUT=$(cd Packages/FleetSecurity && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $SEC_OUT"
if echo "$SEC_OUT" | grep -q ', with 0 failures'; then
  ok "FleetSecurity tests green: $SEC_OUT"
else
  bad "FleetSecurity tests NOT green: $SEC_OUT"
fi

note "FleetPersistence build + tests"
if (cd Packages/FleetPersistence && swift build) >/tmp/d1_pers_build.log 2>&1; then
  ok "FleetPersistence builds"
else
  bad "FleetPersistence build failed"; tail -5 /tmp/d1_pers_build.log
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
if xcodegen generate >/tmp/d1_xcodegen.log 2>&1 && grep -q '3JS22HX92T' HermesFleetApp.xcodeproj/project.pbxproj; then
  ok "xcodegen regenerated; team 3JS22HX92T present"
else
  bad "xcodegen / team missing"; tail -5 /tmp/d1_xcodegen.log
fi
DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataD1"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" build >/tmp/d1_xcbuild.log 2>&1; then
  ok "xcodebuild BUILD SUCCEEDED (iOS Simulator)"
else
  bad "xcodebuild build FAILED"; tail -15 /tmp/d1_xcbuild.log
fi
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" test >/tmp/d1_xctest.log 2>&1; then
  TESTLINE=$(grep -E 'Test Suite.*(passed|failed)' /tmp/d1_xctest.log | tail -1)
  ok "xcodebuild TEST SUCCEEDED — $TESTLINE"
else
  bad "xcodebuild test FAILED"; grep -E 'error:|failed|Test Suite' /tmp/d1_xctest.log | tail -15
fi

# --- 6. Secrets scan (D1 sources) --------------------------------------------
note "Secrets scan (D1 sources)"
SCAN_FILES="Packages/FleetNetworking/Sources/FleetNetworking/GatewayWebSocketTransport.swift
Packages/FleetNetworking/Tests/FleetNetworkingTests/GatewayWebSocketTransportTests.swift
Packages/FleetNetworking/Tests/FleetNetworkingTests/SingleGatewayConnectionTests.swift"
HITS=$(grep -nE '"(sk-|ghp_|gho_|[A-Za-z0-9_-]{20,}token|secret-value|boundary-fixture|top-secret|loop-secret|super-secret)' $SCAN_FILES 2>/dev/null | grep -viE '// |serviceName|rawValue|placeholder|sensitiveQueryKeys|case |wrapped|detail|localizedDescription' || true)
if [ -n "$HITS" ]; then
  bad "possible secret-like literal found in D1 sources:"
  echo "$HITS" | head -10
else
  ok "no hardcoded secret-like literals in D1 sources"
fi

# --- 7. Git state ------------------------------------------------------------
note "Git state"
echo "  branch: $(git rev-parse --abbrev-ref HEAD)"
echo "  changed files:"
git diff --name-status

# --- Summary -----------------------------------------------------------------
printf '\n=====================================\n'
printf 'D1 validate: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
