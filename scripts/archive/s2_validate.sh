#!/bin/bash
# S2 (B1) Stable message identity — full validation.
# Evidence: source fix present (no hashValue fallback; clientID minted + persisted
# through the FleetPersistence seam), regression tests GREEN (previously RED on
# pre-fix code, proven in s2_red_test.sh), all four package suites, xcodegen +
# xcodebuild app build/test on the iOS Simulator, replay dedupe (seq-gated,
# message-id independent), secrets scan, git state.
# Run with: bash scripts/s2_validate.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
PASS=0
FAIL=0
declare -a FAILURES=()

note() { printf '\n=== %s ===\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf 'FAIL  %s\n' "$1"; }

# --- 1. SOURCE FIX: hashValue fallback is gone --------------------------------
note "Source fix: SessionMessage.id never derives from a randomized hash"
if grep -q "text.hashValue" "$REPO"/Packages/FleetCore/Sources/FleetCore/SessionMessage.swift; then
  bad "SessionMessage still contains text.hashValue fallback"
else
  ok "no text.hashValue anywhere in SessionMessage.swift (B1 fixed)"
fi
if grep -q "clientID" "$REPO"/Packages/FleetCore/Sources/FleetCore/SessionMessage.swift; then
  ok "SessionMessage carries a launch-stable clientID minted at construction"
else
  bad "SessionMessage has no clientID field"
fi
if grep -q "clientID ?? (rowID == nil ? UUID().uuidString : nil)" "$REPO"/Packages/FleetCore/Sources/FleetCore/SessionMessage.swift; then
  ok "clientID minted as UUID at construction when no durable row_id"
else
  bad "clientID is not minted at construction"
fi

# --- 2. SOURCE FIX: persistence seam persists + restores clientID --------------
note "Source fix: FleetPersistence seam persists + restores clientID"
if grep -q "clientID: String? = nil" "$REPO"/Packages/FleetPersistence/Sources/FleetPersistence/CacheModels.swift; then
  ok "CachedMessageRow carries a clientID field"
else
  bad "CachedMessageRow has no clientID field"
fi
if grep -q "clientID: message.clientID" "$REPO"/Packages/FleetPersistence/Sources/FleetPersistence/SwiftDataCacheStore.swift; then
  ok "saveHistory persists message.clientID"
else
  bad "saveHistory does not persist clientID"
fi
if grep -q "clientID: row.clientID" "$REPO"/Packages/FleetPersistence/Sources/FleetPersistence/SwiftDataCacheStore.swift; then
  ok "loadHistory restores the persisted clientID"
else
  bad "loadHistory does not restore clientID"
fi

# --- 3. REGRESSION TESTS GREEN (were RED on pre-fix code) ----------------------
note "Regression tests GREEN on fixed code"
CORE_REG=$(cd Packages/FleetCore && swift test \
  --filter "testDuplicateTextMessagesKeepDistinctIDs" \
  --filter "testSynthesizedIDIsLaunchStableUUID" \
  --filter "testMessageIdentityPrefersRowID" 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  FleetCore: $CORE_REG"
if echo "$CORE_REG" | grep -q ', with 0 failures'; then
  ok "FleetCore identity regression tests green"
else
  bad "FleetCore identity regression tests NOT green"
fi
PERS_REG_LOG=/tmp/s2_pers_reg.log
(cd Packages/FleetPersistence && swift test \
  --filter "testFreshContainersRestoreIdenticalMessageIDs" >"$PERS_REG_LOG" 2>&1)
PERS_EXIT=$?
PERS_REG=$(grep -E 'Executed [0-9]+ tests?, with' "$PERS_REG_LOG" | tail -1)
echo "  FleetPersistence: $PERS_REG"
if [ "$PERS_EXIT" -eq 0 ] && echo "$PERS_REG" | grep -q ', with 0 failures'; then
  ok "FleetPersistence fresh-container regression green"
else
  bad "FleetPersistence fresh-container regression NOT green (exit=$PERS_EXIT)"
fi

# --- 4. FULL PACKAGE SUITES ----------------------------------------------------
for PKG in FleetCore FleetNetworking FleetSecurity FleetPersistence; do
  note "$PKG build + full tests"
  if (cd Packages/$PKG && swift build) >/tmp/s2_${PKG}_build.log 2>&1; then
    ok "$PKG builds"
  else
    bad "$PKG build failed"; tail -5 /tmp/s2_${PKG}_build.log
  fi
  OUT=$(cd Packages/$PKG && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
  echo "  $OUT"
  if echo "$OUT" | grep -q ', with 0 failures'; then
    ok "$PKG tests green: $OUT"
  else
    bad "$PKG tests NOT green: $OUT"
  fi
done

# --- 5. REPLAY DEDUPE unaffected (seq-gated, not message-id based) -------------
note "Replay dedupe unaffected (ReconnectReplayTests green)"
if grep -q "filter { (\$0.seq ?? 0) > lastSeen }" "$REPO"/Packages/FleetNetworking/Sources/FleetNetworking/GatewayReplayEngine.swift; then
  ok "replay dedupe is seq-gated (lastSeen), independent of SessionMessage.id"
else
  bad "replay dedupe gate changed or not found"
fi
RR=$(cd Packages/FleetNetworking && swift test --filter "ReconnectReplayTests" 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $RR"
if echo "$RR" | grep -q ', with 0 failures'; then
  ok "ReconnectReplayTests green (dedupe unaffected)"
else
  bad "ReconnectReplayTests NOT green"
fi

# --- 6. XCODEGEN + XCODEBUILD build/test (iOS Simulator, app-level) ------------
note "xcodegen + xcodebuild build/test (iOS Simulator)"
if xcodegen generate >/tmp/s2_xcodegen.log 2>&1 && grep -q '3JS22HX92T' HermesFleetApp.xcodeproj/project.pbxproj; then
  ok "xcodegen regenerated; team 3JS22HX92T present"
else
  bad "xcodegen / team missing"; tail -5 /tmp/s2_xcodegen.log
fi
DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataS2"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" build >/tmp/s2_xcbuild.log 2>&1; then
  ok "xcodebuild BUILD SUCCEEDED (iOS Simulator)"
else
  bad "xcodebuild build FAILED"; tail -25 /tmp/s2_xcbuild.log
fi
# App UNIT-test bundle (gateway-independent: ModuleBoundary, seam, app-level
# persistence) — the repo convention (p3fix_final_validate.sh) gates on this.
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:HermesFleetAppTests test >/tmp/s2_xctest.log 2>&1; then
  TESTLINE=$(grep -E 'Test Suite.*(passed|failed)' /tmp/s2_xctest.log | tail -1)
  ok "xcodebuild app UNIT tests SUCCEEDED — $TESTLINE"
else
  bad "xcodebuild app unit tests FAILED"; grep -E 'error:|failed|Test Suite' /tmp/s2_xctest.log | tail -20
fi
# Live-gateway UI tests (P3Fix) are environmental: they need a live LAN gateway
# + clean simulator app state and are NOT part of the deterministic suite. They
# fail identically on base main (verified via git-stash base run, exit 65 same
# line 168) — a B1-independent, pre-existing environmental flake. Reported here
# as informational only; the S2 gate is the deterministic suite above.
note "Live-gateway UI tests (P3Fix) — informational (environmental, not gated)"
LAN_HOST="${HERMES_FLEET_LAN_HOST:-}"
LAN_PORT="${HERMES_FLEET_LAN_PORT:-9120}"
if [ -n "$LAN_HOST" ] && nc -z -w 3 "$LAN_HOST" "$LAN_PORT" >/dev/null 2>&1; then
  echo "  gateway $LAN_HOST:$LAN_PORT reachable; live-gateway UI tests require a"
  echo "  clean simulator + the live surface (pre-existing flake on base, not B1)."
else
  echo "  gateway ${HERMES_FLEET_LAN_HOST:-unset}:$LAN_PORT NOT reachable — live-gateway UI tests skipped."
fi

# --- 7. Secrets scan (touched sources) ----------------------------------------
note "Secrets scan (touched sources)"
SCAN_FILES=$(find Packages/FleetCore/Sources/FleetCore Packages/FleetPersistence/Sources/FleetPersistence HermesFleetApp HermesFleetAppTests -name '*.swift' 2>/dev/null)
HITS=$(grep -nE '"(sk-|ghp_|gho_|[A-Za-z0-9_-]{20,}token|secret-value|boundary-fixture|top-secret|loop-secret|super-secret)' $SCAN_FILES 2>/dev/null | grep -viE '// |rawValue|placeholder|localizedDescription|sessionToken: nil|boundary-fixture|top-secret-in-app|app-secret-ticket-value|app-loop-secret|secret-ticket-xyz|loop-token-abc|fixture-token|fixture-ticket' || true)
if [ -n "$HITS" ]; then
  bad "possible secret-like literal found:"
  echo "$HITS" | head -10
else
  ok "no hardcoded secret-like literals in touched sources"
fi

# --- 8. Git state --------------------------------------------------------------
note "Git state"
echo "  branch: $(git rev-parse --abbrev-ref HEAD)"
echo "  changed files:"
git diff --name-status

printf '\n=====================================\n'
printf 'S2 validate: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
