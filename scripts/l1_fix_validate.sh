#!/bin/bash
# L1 fix (t_c0bfc604): full validation of the app auth-wiring fix.
# Verifies all three L1 findings are fixed in source + tests, then runs the
# complete package + app test suites and the live-gateway Release XCUITest.
# Evidence: docs/L1-fix.md + build/l1-fix/*.png + test result lines.
# Run with: bash scripts/l1_fix_validate.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
PASS=0
FAIL=0
declare -a FAILURES=()

note() { printf '\n=== %s ===\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf 'FAIL  %s\n' "$1"; }

# --- 1. Finding #1 fixed in source: authenticator reads CredentialStoring ---
note "Finding #1 — loopback authenticator reads CredentialStoring (the UI's store)"
GOT=$(grep -c "CredentialStoring" "$REPO"/Packages/FleetNetworking/Sources/FleetNetworking/GatewayAuthenticator.swift)
if [ "$GOT" -ge 1 ]; then
  ok "GatewayAuthenticator loads credentials from CredentialStoring (not TokenStoring)"
else
  bad "GatewayAuthenticator does not reference CredentialStoring"
fi
if grep -q "tokenStore" "$REPO"/HermesFleetApp/FleetServiceGraph.swift; then
  bad "FleetServiceGraph still references tokenStore"
else
  ok "FleetServiceGraph no longer wires a token store (single credential store)"
fi

# --- 2. Finding #2 fixed in source: saveCredential preserves strategy --------
note "Finding #2 — saveCredential preserves the configured strategy"
if grep -q "strategy: gateway.authConfiguration.strategy" "$REPO"/Packages/FleetNetworking/Sources/FleetNetworking/GatewayRegistryService.swift; then
  ok "saveCredential preserves the gateway's configured strategy"
else
  bad "saveCredential does not preserve the configured strategy"
fi

# --- 3. Finding #3 fixed in source: ticket minter built from credential ------
note "Finding #3 — session/bearer minter built from stored credential"
if grep -q "sessionToken: credential.rawValue" "$REPO"/Packages/FleetNetworking/Sources/FleetNetworking/GatewayAuthenticator.swift; then
  ok "ticket minter is built with the stored credential (X-Hermes-Session-Token)"
else
  bad "ticket minter does not use the stored credential"
fi

# --- 4. Regression tests present ---------------------------------------------
note "Regression tests for the three findings"
for t in testLoopbackCredentialStoredViaRegistryReachesAuthenticator \
         testSessionTokenAuthenticatorSendsStoredCredentialAsHeader \
         testSaveCredentialPreservesConfiguredStrategy; do
  if grep -q "$t" "$REPO"/Packages/FleetNetworking/Tests/FleetNetworkingTests/*.swift; then
    ok "regression test present: $t"
  else
    bad "missing regression test: $t"
  fi
done

# --- 5. Package test suites --------------------------------------------------
note "Package suites (Core/Networking/Security/Persistence)"
for pkg in FleetCore FleetNetworking FleetSecurity FleetPersistence; do
  OUT=$(cd "Packages/$pkg" && swift test 2>&1 | grep -E "Executed [0-9]+ tests, with [0-9]+ failures" | tail -1)
  echo "  $pkg: $OUT"
  if echo "$OUT" | grep -q ", with 0 failures"; then
    ok "$pkg tests green: $OUT"
  else
    bad "$pkg tests NOT green: $OUT"
  fi
done

# --- 6. App-level xcodebuild test -------------------------------------------
note "App-level xcodebuild test (unit + ModuleBoundary)"
DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/L1Fix-DerivedData"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:HermesFleetAppTests \
    test >/tmp/l1fix_xctest.log 2>&1; then
  TESTLINE=$(grep -E 'Executed [0-9]+ tests, with [0-9]+ failures' /tmp/l1fix_xctest.log | tail -1)
  ok "app unit tests green: $TESTLINE"
else
  bad "app unit tests FAILED"; grep -E 'error:|failed' /tmp/l1fix_xctest.log | tail -10
fi

# --- 7. Live-gateway Release XCUITest (requires serve on :9119) --------------
note "Live-gateway Release XCUITest (L1FixLiveGatewayUITests)"
if lsof -nP -iTCP:9119 -sTCP:LISTEN >/dev/null 2>&1; then
  if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
      -destination "$DEST" -derivedDataPath "$DD" -configuration Release \
      -only-testing:HermesFleetAppUITests/L1FixLiveGatewayUITests \
      test >/tmp/l1fix_ui_test.log 2>&1; then
    TESTLINE=$(grep -E "Test Suite 'L1FixLiveGatewayUITests' (passed|failed)" /tmp/l1fix_ui_test.log | tail -1)
    ok "live-gateway XCUITest $TESTLINE"
  else
    bad "live-gateway XCUITest FAILED"; grep -E 'error:|Assertion' /tmp/l1fix_ui_test.log | tail -10
  fi
else
  bad "no serve on :9119 — start with scripts/l1_start_serve.sh first"
fi

# --- 8. Secrets scan ---------------------------------------------------------
note "Secrets scan (test token must not appear in committed files)"
if [ -f /tmp/l1_live_test/.token ]; then
  TOK=$(cat /tmp/l1_live_test/.token)
  CNT=$(grep -rF "$TOK" HermesFleetApp HermesFleetAppTests HermesFleetAppUITests docs scripts Packages 2>/dev/null | grep -v '^Binary' | wc -l | tr -d ' ')
  if [ "$CNT" = "0" ]; then
    ok "test token appears in 0 committed files"
  else
    bad "test token found in $CNT committed files"
  fi
else
  echo "  (token file cleaned — as expected)"
  ok "token file absent (nothing to leak)"
fi

# --- 9. Git state ------------------------------------------------------------
note "Git state"
echo "  branch: $(git rev-parse --abbrev-ref HEAD)"
git diff --name-status

printf '\n=====================================\n'
printf 'L1 fix validate: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
