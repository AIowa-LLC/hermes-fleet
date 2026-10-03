#!/bin/bash
# S3 (B2) Cleartext warning in gateway form — full validation.
# Evidence: classifier source fix present, classifier unit tests GREEN
# (previously RED on base, proven in s3_red_test.sh), all four package suites,
# xcodegen + xcodebuild app build/test on the iOS Simulator (incl. the S3
# cleartext-warning UI tests), secrets scan, git state.
# Run with: bash scripts/s3_validate.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
PASS=0
FAIL=0
declare -a FAILURES=()

note() { printf '\n=== %s ===\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf 'FAIL  %s\n' "$1"; }

# --- 0. BRANCH GUARD: must run on main, not C1's probe branch ----------------
note "Branch guard"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "  branch: $BRANCH"
if [ "$BRANCH" = "main" ]; then
  ok "on main (integration line)"
else
  bad "NOT on main (on '$BRANCH') — C1's red-probe branch must not pollute S3 validation"
fi
if [ -f "$REPO/HermesFleetAppTests/C1RedProbeTests.swift" ]; then
  bad "C1RedProbeTests.swift present in working tree — C1's deliberately-red probe would fail the app-unit gate"
else
  ok "C1RedProbeTests.swift absent (probe lives on c1-red-probe only)"
fi

# --- 1. SOURCE FIX: classifier + UI gate present -----------------------------
note "Source fix: PrivateNetwork.isPrivateOrLoopbackHost classifier + form gate"
CORE_SRC="$REPO/Packages/FleetCore/Sources/FleetCore/PrivateNetwork.swift"
if [ -f "$CORE_SRC" ] && grep -q "public static func isPrivateOrLoopbackHost" "$CORE_SRC"; then
  ok "PrivateNetwork.isPrivateOrLoopbackHost exists in FleetCore"
else
  bad "classifier missing from FleetCore"
fi
if grep -q 'a == 10' "$CORE_SRC" && grep -q 'a == 172 && b >= 16 && b <= 31' "$CORE_SRC" \
   && grep -q 'a == 192 && b == 168' "$CORE_SRC" && grep -q 'a == 127' "$CORE_SRC"; then
  ok "RFC1918 (10/8, 172.16/12, 192.168/16) + loopback 127/8 classified"
else
  bad "RFC1918/loopback ranges not all present in classifier"
fi
if grep -q 'h == "::1"' "$CORE_SRC" && grep -q 'h == "localhost"' "$CORE_SRC" \
   && grep -q 'h.hasSuffix(".local")' "$CORE_SRC"; then
  ok "IPv6 ::1 loopback, localhost, and .local classified"
else
  bad "::1/localhost/.local not all present in classifier"
fi

FORM="$REPO/Packages/FleetUI/Sources/FleetUI/GatewayFormSheet.swift"
if grep -q 'PrivateNetwork.isPrivateOrLoopbackHost' "$FORM"; then
  ok "GatewayFormSheet consumes PrivateNetwork.isPrivateOrLoopbackHost"
else
  bad "GatewayFormSheet does not call the classifier"
fi
if grep -q 'cleartextRisk' "$FORM" && grep -q 'confirmsCleartextSend' "$FORM" \
   && grep -q '!cleartextRisk || confirmsCleartextSend' "$FORM"; then
  ok "Save gated on explicit cleartext confirmation"
else
  bad "save-gating on cleartext confirmation not wired"
fi
if grep -q 'fleet.gateways.form.cleartext-warning' "$FORM" \
   && grep -q 'fleet.gateways.form.cleartext-confirm' "$FORM"; then
  ok "warning + confirm UI identifiers present (UI-testable)"
else
  bad "warning/confirm accessibility identifiers missing"
fi

# --- 2. CLASSIFIER UNIT TESTS GREEN (were RED on base) -----------------------
note "Classifier unit tests GREEN (PrivateNetworkClassifierTests)"
OUT=$(cd Packages/FleetCore && swift test --filter "PrivateNetworkClassifierTests" 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $OUT"
if echo "$OUT" | grep -q ', with 0 failures'; then
  ok "classifier unit tests green: $OUT"
else
  bad "classifier unit tests NOT green: $OUT"
fi

# --- 3. FULL PACKAGE SUITES --------------------------------------------------
for PKG in FleetCore FleetNetworking FleetSecurity FleetPersistence; do
  note "$PKG build + full tests"
  if (cd Packages/$PKG && swift build) >/tmp/s3_${PKG}_build.log 2>&1; then
    ok "$PKG builds"
  else
    bad "$PKG build failed"; tail -5 /tmp/s3_${PKG}_build.log
  fi
  POUT=$(cd Packages/$PKG && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
  echo "  $POUT"
  if echo "$POUT" | grep -q ', with 0 failures'; then
    ok "$PKG tests green: $POUT"
  else
    bad "$PKG tests NOT green: $POUT"
  fi
done

# --- 4. XCODEGEN + XCODEBUILD build/test (iOS Simulator) ---------------------
note "xcodegen + xcodebuild build/test (iOS Simulator)"
if xcodegen generate >/tmp/s3_xcodegen.log 2>&1 && grep -q '3JS22HX92T' HermesFleetApp.xcodeproj/project.pbxproj; then
  ok "xcodegen regenerated; team 3JS22HX92T present"
else
  bad "xcodegen / team missing"; tail -5 /tmp/s3_xcodegen.log
fi
DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataS3"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" build >/tmp/s3_xcbuild.log 2>&1; then
  ok "xcodebuild BUILD SUCCEEDED (iOS Simulator)"
else
  bad "xcodebuild build FAILED"; grep -E "error:" /tmp/s3_xcbuild.log | head -20
fi
# App UNIT-test bundle (gateway-independent) — the repo convention.
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:HermesFleetAppTests test >/tmp/s3_xctest.log 2>&1; then
  TESTLINE=$(grep -E 'Test Suite.*(passed|failed)' /tmp/s3_xctest.log | tail -1)
  ok "xcodebuild app UNIT tests SUCCEEDED — $TESTLINE"
else
  bad "xcodebuild app unit tests FAILED"; grep -E 'error:|failed|Test Suite' /tmp/s3_xctest.log | tail -20
fi
# S3 cleartext-warning UI tests (deterministic — scripted fleet, no live
# gateway). These are the B2 acceptance UI tests.
note "S3 cleartext-warning UI tests (scripted fleet)"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:HermesFleetAppUITests/S3CleartextWarningUITests test >/tmp/s3_xcuit.log 2>&1; then
  UILINE=$(grep -E 'Test Suite.*(passed|failed)' /tmp/s3_xcuit.log | tail -1)
  ok "S3 cleartext-warning UI tests SUCCEEDED — $UILINE"
else
  bad "S3 cleartext-warning UI tests FAILED"; grep -E 'error:|failed|Test Case.*failed' /tmp/s3_xcuit.log | tail -20
fi

# --- 5. Secrets scan (S3-touched files ONLY — sweeping all of
#         HermesFleetAppUITests would flag pre-existing L1 screenshot names) ---
note "Secrets scan (S3-touched files)"
SCAN_FILES="$REPO/Packages/FleetCore/Sources/FleetCore/PrivateNetwork.swift
$REPO/Packages/FleetCore/Tests/FleetCoreTests/PrivateNetworkClassifierTests.swift
$REPO/Packages/FleetUI/Sources/FleetUI/GatewayFormSheet.swift
$REPO/HermesFleetAppUITests/S3CleartextWarningUITests.swift"
HITS=$(grep -nE '\"(sk-|ghp_|gho_|[A-Za-z0-9_-]{20,}token|secret-value|boundary-fixture|top-secret|loop-secret|super-secret)' $SCAN_FILES 2>/dev/null | grep -viE '// |rawValue|placeholder|localizedDescription|sessionToken: nil|boundary-fixture|top-secret-in-app|app-secret-ticket-value|app-loop-secret|secret-ticket-xyz|loop-token-abc|fixture-token|fixture-ticket' || true)
if [ -n "$HITS" ]; then
  bad "possible secret-like literal found:"
  echo "$HITS" | head -10
else
  ok "no hardcoded secret-like literals in touched sources"
fi

# --- 6. Git state ------------------------------------------------------------
note "Git state"
echo "  branch: $(git rev-parse --abbrev-ref HEAD)"
echo "  changed files:"
git diff --name-status

printf '\n=====================================\n'
printf 'S3 validate: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
