#!/bin/bash
# M11 Authentication Hardening validation — run with: bash m11_validate.sh
# Scope: AuthenticationProvider seam + single-use 30s ticket TTL + loopback
# token (?token=) + 4401 re-auth no silent retry + redaction (no credentials
# in logs/cache/UI). Built on M10 commit 1e4bbeb.
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
if (cd Packages/FleetCore && swift build) >/tmp/m11_core_build.log 2>&1; then
  ok "FleetCore builds"
else
  bad "FleetCore build failed"; tail -5 /tmp/m11_core_build.log
fi
CORE_OUT=$(cd Packages/FleetCore && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $CORE_OUT"
if echo "$CORE_OUT" | grep -q ', with 0 failures'; then
  ok "FleetCore tests green: $CORE_OUT"
else
  bad "FleetCore tests NOT green: $CORE_OUT"
fi

# --- 2. FleetNetworking build + tests --------------------------------------
note "FleetNetworking build + tests"
if (cd Packages/FleetNetworking && swift build) >/tmp/m11_net_build.log 2>&1; then
  ok "FleetNetworking builds"
else
  bad "FleetNetworking build failed"; tail -8 /tmp/m11_net_build.log
fi
NET_OUT=$(cd Packages/FleetNetworking && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $NET_OUT"
if echo "$NET_OUT" | grep -q ', with 0 failures'; then
  ok "FleetNetworking tests green: $NET_OUT"
else
  bad "FleetNetworking tests NOT green: $NET_OUT"
fi

# --- 3. FleetSecurity build + tests (regression; M11 touches shared seams) --
note "FleetSecurity build + tests"
if (cd Packages/FleetSecurity && swift build) >/tmp/m11_sec_build.log 2>&1; then
  ok "FleetSecurity builds"
else
  bad "FleetSecurity build failed"; tail -5 /tmp/m11_sec_build.log
fi
SEC_OUT=$(cd Packages/FleetSecurity && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $SEC_OUT"
if echo "$SEC_OUT" | grep -q ', with 0 failures'; then
  ok "FleetSecurity tests green: $SEC_OUT"
else
  bad "FleetSecurity tests NOT green: $SEC_OUT"
fi

# --- 4. FleetPersistence build + tests (regression) -------------------------
note "FleetPersistence build + tests"
if (cd Packages/FleetPersistence && swift build) >/tmp/m11_pers_build.log 2>&1; then
  ok "FleetPersistence builds"
else
  bad "FleetPersistence build failed"; tail -5 /tmp/m11_pers_build.log
fi
PERS_OUT=$(cd Packages/FleetPersistence && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $PERS_OUT"
if echo "$PERS_OUT" | grep -q ', with 0 failures'; then
  ok "FleetPersistence tests green: $PERS_OUT"
else
  bad "FleetPersistence tests NOT green: $PERS_OUT"
fi

# --- 5. xcodegen + xcodebuild build (iOS Simulator) ------------------------
note "xcodegen + xcodebuild build (iOS Simulator)"
if xcodegen generate >/tmp/m11_xcodegen.log 2>&1 && grep -q '3JS22HX92T' HermesFleetApp.xcodeproj/project.pbxproj; then
  ok "xcodegen regenerated; team 3JS22HX92T present"
else
  bad "xcodegen / team missing"; tail -5 /tmp/m11_xcodegen.log
fi
DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataM11"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" build >/tmp/m11_xcbuild.log 2>&1; then
  ok "xcodebuild BUILD SUCCEEDED (iOS Simulator)"
else
  bad "xcodebuild build FAILED"; tail -15 /tmp/m11_xcbuild.log
fi

# --- 6. xcodebuild test (iOS Simulator app-level boundary tests) ------------
note "xcodebuild test (iOS Simulator, app-level)"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" test >/tmp/m11_xctest.log 2>&1; then
  TESTLINE=$(grep -E 'Test Suite.*(passed|failed)' /tmp/m11_xctest.log | tail -1)
  ok "xcodebuild TEST SUCCEEDED — $TESTLINE"
else
  bad "xcodebuild test FAILED"; grep -E 'error:|failed|Test Suite' /tmp/m11_xctest.log | tail -15
fi

# --- 7. Secrets scan (M11 sources) ------------------------------------------
note "Secrets scan (M11 sources)"
SCAN_FILES="Packages/FleetCore/Sources/FleetCore/ConnectionAuthentication.swift
Packages/FleetCore/Sources/FleetCore/Redaction.swift
Packages/FleetNetworking/Sources/FleetNetworking/GatewayAuthenticator.swift
Packages/FleetNetworking/Sources/FleetNetworking/WSTicket.swift
Packages/FleetNetworking/Sources/FleetNetworking/GatewayWebSocketTransport.swift
Packages/FleetNetworking/Sources/FleetNetworking/SingleGatewayConnection.swift"
HITS=$(grep -nE '"(sk-|ghp_|gho_|[A-Za-z0-9_-]{20,}token|secret-value|boundary-fixture|top-secret|loop-secret|super-secret)' $SCAN_FILES 2>/dev/null | grep -viE '// |serviceName|rawValue|placeholder|sensitiveQueryKeys|case |wrapped|detail|localizedDescription' || true)
if [ -n "$HITS" ]; then
  bad "possible secret-like literal found in M11 sources:"
  echo "$HITS" | head -10
else
  ok "no hardcoded secret-like literals in M11 sources"
fi

# --- 8. Redaction structural checks -----------------------------------------
note "Redaction structural checks"
# 8a. WSTicket / StoredToken / ConnectionAuthentication must not print secrets.
if grep -qE 'public var (description|debugDescription).*\[' Packages/FleetNetworking/Sources/FleetNetworking/WSTicket.swift \
   && grep -qE '\[REDACTED\]' Packages/FleetNetworking/Sources/FleetNetworking/WSTicket.swift; then
  ok "WSTicket redacted description present"
else
  bad "WSTicket missing redacted description"
fi
# 8b. No secret-named stored properties leaked into cache (structural).
SECRET_FIELDS=$(grep -RniE 'var[[:space:]]+(token|ticket|credential|password|secret)' Packages/FleetPersistence/Sources 2>/dev/null || true)
if [ -n "$SECRET_FIELDS" ]; then
  bad "cache model contains a secret-named stored property:"; echo "$SECRET_FIELDS" | head -5
else
  ok "FleetPersistence cache models contain no secret-named stored properties"
fi
# 8c. Auth provider seam exists in FleetCore.
if [ -f Packages/FleetCore/Sources/FleetCore/ConnectionAuthentication.swift ] \
   && grep -q 'protocol AuthenticationProviding' Packages/FleetCore/Sources/FleetCore/ConnectionAuthentication.swift; then
  ok "AuthenticationProviding seam present in FleetCore"
else
  bad "AuthenticationProviding seam missing"
fi
# 8d. Redaction utility present.
if grep -q 'enum Redaction' Packages/FleetCore/Sources/FleetCore/Redaction.swift; then
  ok "Redaction utility present"
else
  bad "Redaction utility missing"
fi

# --- 9. SwiftUI isolation guard ---------------------------------------------
note "SwiftUI isolation grep"
UI_IMPORTS=$(grep -Rl 'import FleetNetworking' Packages/FleetUI/Sources 2>/dev/null || true)
if [ -n "$UI_IMPORTS" ]; then
  bad "FleetUI imports FleetNetworking (M0 guard broken):"; echo "$UI_IMPORTS" | head -5
else
  ok "0 'import FleetNetworking' in Packages/FleetUI/Sources"
fi

# --- Summary -----------------------------------------------------------------
printf '\n=====================================\n'
printf 'M11 validate: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
