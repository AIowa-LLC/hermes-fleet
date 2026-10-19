#!/bin/bash
# M10 Persistence/Cache validation — run with: bash m10_validate.sh
# Scope: Keychain token/ticket store (FleetSecurity) + SwiftData non-secret
# cache (FleetPersistence) + NSFileProtectionComplete + no tokens in cache.
set -u
cd "$(dirname "$0")"
REPO="$(pwd)"
PASS=0
FAIL=0
declare -a FAILURES=()

note() { printf '\n=== %s ===\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf 'FAIL  %s\n' "$1"; }

# --- 1. FleetCore build + tests ---------------------------------------------
note "FleetCore build + tests"
if (cd Packages/FleetCore && swift build) >/tmp/m10_core_build.log 2>&1; then
  ok "FleetCore builds"
else
  bad "FleetCore build failed"; tail -5 /tmp/m10_core_build.log
fi
CORE_OUT=$(cd Packages/FleetCore && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $CORE_OUT"
if echo "$CORE_OUT" | grep -q ', with 0 failures'; then
  ok "FleetCore tests green: $CORE_OUT"
else
  bad "FleetCore tests NOT green: $CORE_OUT"
fi

# --- 2. FleetSecurity build + tests ----------------------------------------
note "FleetSecurity build + tests"
if (cd Packages/FleetSecurity && swift build) >/tmp/m10_sec_build.log 2>&1; then
  ok "FleetSecurity builds"
else
  bad "FleetSecurity build failed"; tail -5 /tmp/m10_sec_build.log
fi
SEC_OUT=$(cd Packages/FleetSecurity && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $SEC_OUT"
if echo "$SEC_OUT" | grep -q ', with 0 failures'; then
  ok "FleetSecurity tests green: $SEC_OUT"
else
  bad "FleetSecurity tests NOT green: $SEC_OUT"
fi

# --- 3. FleetPersistence build + tests -------------------------------------
note "FleetPersistence build + tests"
if (cd Packages/FleetPersistence && swift build) >/tmp/m10_pers_build.log 2>&1; then
  ok "FleetPersistence builds"
else
  bad "FleetPersistence build failed"; tail -8 /tmp/m10_pers_build.log
fi
PERS_OUT=$(cd Packages/FleetPersistence && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $PERS_OUT"
if echo "$PERS_OUT" | grep -q ', with 0 failures'; then
  ok "FleetPersistence tests green: $PERS_OUT"
else
  bad "FleetPersistence tests NOT green: $PERS_OUT"
fi

# --- 4. xcodegen + xcodebuild build (iOS Simulator) ------------------------
note "xcodegen + xcodebuild build (iOS Simulator)"
if xcodegen generate >/tmp/m10_xcodegen.log 2>&1 && grep -q '3JS22HX92T' HermesFleetApp.xcodeproj/project.pbxproj; then
  ok "xcodegen regenerated; team 3JS22HX92T present"
else
  bad "xcodegen / team missing"; tail -5 /tmp/m10_xcodegen.log
fi
DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataM10"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" build >/tmp/m10_xcbuild.log 2>&1; then
  ok "xcodebuild BUILD SUCCEEDED (iOS Simulator)"
else
  bad "xcodebuild build FAILED"; tail -15 /tmp/m10_xcbuild.log
fi

# --- 5. xcodebuild test (iOS Simulator app-level boundary tests) ------------
note "xcodebuild test (iOS Simulator, app-level)"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" test >/tmp/m10_xctest.log 2>&1; then
  TESTLINE=$(grep -E 'Test Suite.*(passed|failed)' /tmp/m10_xctest.log | tail -1)
  ok "xcodebuild TEST SUCCEEDED — $TESTLINE"
else
  bad "xcodebuild test FAILED"; grep -E 'error:|failed|Test Suite' /tmp/m10_xctest.log | tail -15
fi

# --- 6. Secrets scan (M10 sources only) -------------------------------------
note "Secrets scan (M10 sources)"
SCAN_FILES="Packages/FleetCore/Sources/FleetCore/CacheStoring.swift
Packages/FleetCore/Sources/FleetCore/TokenStoring.swift
Packages/FleetSecurity/Sources/FleetSecurity/KeychainTokenStore.swift
Packages/FleetSecurity/Sources/FleetSecurity/InMemoryTokenStore.swift
Packages/FleetPersistence/Sources/FleetPersistence/SwiftDataCacheStore.swift
Packages/FleetPersistence/Sources/FleetPersistence/CacheModels.swift"
# Look for hardcoded secret-like literals (fixture values allowed only in Tests/).
HITS=$(grep -nE '"(sk-|ghp_|gho_|[A-Za-z0-9_-]{20,}token|secret-value|boundary-fixture)' $SCAN_FILES 2>/dev/null | grep -viE '// |serviceName|"token"|"ticket"|rawValue|forbidden' || true)
if [ -n "$HITS" ]; then
  bad "possible secret-like literal found in M10 sources:"
  echo "$HITS" | head -10
else
  ok "no hardcoded secret-like literals in M10 sources"
fi

# --- 7. Structural: no tokens in cache (source-level) ----------------------
note "No-token-in-cache structural check"
SECRET_FIELDS=$(grep -RniE 'var[[:space:]]+(token|ticket|credential|password|secret)' Packages/FleetPersistence/Sources 2>/dev/null || true)
if [ -n "$SECRET_FIELDS" ]; then
  bad "cache model contains a secret-named stored property:"; echo "$SECRET_FIELDS" | head -5
else
  ok "FleetPersistence cache models contain no secret-named stored properties"
fi
TOKEN_API=$(grep -RniE 'saveToken|loadToken|deleteToken' Packages/FleetPersistence/Sources 2>/dev/null || true)
if [ -n "$TOKEN_API" ]; then
  bad "cache store exposes a token API:"; echo "$TOKEN_API" | head -5
else
  ok "FleetPersistence cache store exposes no token API (tokens are Keychain-only)"
fi

# --- 8. SwiftUI isolation guard ---------------------------------------------
note "SwiftUI isolation grep"
UI_IMPORTS=$(grep -Rl 'import FleetNetworking' Packages/FleetUI/Sources 2>/dev/null || true)
if [ -n "$UI_IMPORTS" ]; then
  bad "FleetUI imports FleetNetworking (M0 guard broken):"; echo "$UI_IMPORTS" | head -5
else
  ok "0 'import FleetNetworking' in Packages/FleetUI/Sources"
fi

# --- Summary -----------------------------------------------------------------
printf '\n=====================================\n'
printf 'M10 validate: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
