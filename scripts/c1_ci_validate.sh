#!/bin/bash
# C1 CI validation script — invoked by .github/workflows/ci.yml on every PR +
# main push (paths-filtered). Mirrors the card's mandated pipeline:
#   xcodegen generate -> swift test (4 packages) -> xcodebuild build+test
#   (simulator) -> module-boundary check -> secrets scan (gitleaks).
# Also runnable locally: bash scripts/c1_ci_validate.sh
#
# DESIGN NOTES (read before editing):
#  - FleetUI imports UIKit, so it cannot `swift test` on the macOS host; the
#    card's "4 packages" = FleetCore / FleetNetworking / FleetPersistence /
#    FleetSecurity. FleetUI is validated via the module-boundary check + the
#    app's hosted ModuleBoundaryTests below.
#  - xcodebuild test is gated with -only-testing selectors. The unit test
#    bundle runs fully. The UI-test bundle's DETERMINISTIC scripted-fleet
#    suites (DEBUG build — HappyPath, Reconnect, S3CleartextWarning, plus the
#    RT2 removal/endpoint-sanitization, H1 app-lock and RT4 UX suites) run in
#    CI too. The ENVIRONMENTAL live-gateway suites (L1*/P3Fix*/T2Fix*/H2 —
#    need a real `hermes serve` / Tony's home LAN / Tailscale) are
#    intentionally NOT part of CI: they run locally against the live gateway.
#    This was the P1-7 fix: previously `-only-testing:HermesFleetAppTests`
#    excluded the ENTIRE UI bundle, so navigation/composer/reconnect/form
#    regressions could merge with green CI.
#  - P1-7 regression fix (t_ea9f4624): NEVER mix a bare-bundle
#    `-only-testing:<Bundle>` selector with class-level
#    `-only-testing:<Bundle>/<Class>` selectors in ONE xcodebuild test
#    invocation — xcodebuild then runs ONLY the class-level selections and
#    silently drops the bare bundle (the ~90-test HermesFleetAppTests unit
#    bundle stopped running in CI: RT2 "Executed 78 tests" before, RT4/RT5
#    "Executed 14 tests" after). The unit bundle and the deterministic UI
#    suites are therefore run as TWO separate xcodebuild test invocations
#    (step 4a + 4b): a bare-bundle selector is safe on its own, and
#    class-level selectors on their own.
#  - CODE_SIGNING_ALLOWED must NOT be set to NO: the 4 Keychain-backed tests
#    in ModuleBoundaryTests require the keychain-access-groups entitlement
#    that only gets embedded when the app is signed. Simulator builds on
#    GitHub runners ad-hoc sign without any certificate, so default signing
#    is exactly right.
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
PASS=0
FAIL=0
declare -a FAILURES=()
note() { printf '\n=== %s ===\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf 'FAIL  %s\n' "$1"; }

# --- 1. xcodegen generate ----------------------------------------------------
note "xcodegen generate"
if xcodegen generate >/tmp/c1_xcodegen.log 2>&1; then
  ok "xcodegen generate succeeded"
else
  bad "xcodegen generate FAILED"; tail -5 /tmp/c1_xcodegen.log
fi

# --- 2. swift test (4 packages) ----------------------------------------------
run_pkg() {
  local name=$1 out
  note "$name swift test"
  out=$(cd "Packages/$name" && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
  echo "  $out"
  if echo "$out" | grep -q ', with 0 failures'; then
    ok "$name swift test green: $out"
  else
    bad "$name swift test NOT green: $out"
  fi
}
run_pkg FleetCore
run_pkg FleetNetworking
run_pkg FleetPersistence
run_pkg FleetSecurity

# --- 3. module-boundary check ------------------------------------------------
note "Module boundary: no 'import FleetNetworking' in FleetUI sources"
UI_SOURCES=$(find Packages/FleetUI/Sources -name '*.swift')
HITS=$(grep -nE '^\s*import\s+FleetNetworking\b' $UI_SOURCES 2>/dev/null || true)
if [ -z "$HITS" ]; then
  ok "FleetUI has 0 'import FleetNetworking' (M0 hard guard preserved)"
else
  bad "FleetUI imports FleetNetworking:"; echo "$HITS"
fi

# --- 4. xcodebuild build+test (simulator), reliable unit + deterministic UI ---
note "xcodebuild build + test (simulator): HermesFleetAppTests + deterministic UI suites"
# Resolve the first available iPhone simulator (runner images differ).
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
echo "  using simulator: $SIM_NAME"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
DD="$REPO/build/C1Ci"
# P1-7 fix (t_ea9f4624): the unit bundle and the deterministic scripted-fleet
# UI suites MUST be two separate xcodebuild test invocations — a bare-bundle
# -only-testing selector mixed with class-level selectors makes xcodebuild
# drop the bare bundle (see design notes). The environmental live-gateway
# suites (L1*/P3Fix*/T2Fix*/H2) are NOT selected here — they stay gated/manual.
XC=(-project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD")

# 4a. FULL app-hosted unit bundle (HermesFleetAppTests, ~90 tests: M0 module
#     boundary, AppEnvironment, ConversationViewModel incl. P1-5 regressions,
#     AppLock, FleetCoreLogic, AppComposition, fixture loop, RT4 logic).
if xcodebuild "${XC[@]}" -only-testing:HermesFleetAppTests \
    build test >/tmp/c1_xctest_unit.log 2>&1; then
  ULINE=$(grep -E 'Executed .* tests' /tmp/c1_xctest_unit.log | tail -1)
  ok "xcodebuild UNIT tests (HermesFleetAppTests) SUCCEEDED — $ULINE"
  echo "  $ULINE"
else
  bad "xcodebuild UNIT tests (HermesFleetAppTests) FAILED"
  grep -E 'error:|failed|Test Suite|Executed' /tmp/c1_xctest_unit.log | tail -25
fi

# 4b. DETERMINISTIC scripted-fleet UI suites (DEBUG build, no live gateway
#     needed). Class-level selectors only — safe on their own.
if xcodebuild "${XC[@]}" \
    -only-testing:HermesFleetAppUITests/HermesFleetHappyPathUITests \
    -only-testing:HermesFleetAppUITests/HermesFleetReconnectUITests \
    -only-testing:HermesFleetAppUITests/S3CleartextWarningUITests \
    -only-testing:HermesFleetAppUITests/RT2RemovalAndEndpointSanitizationUITests \
    -only-testing:HermesFleetAppUITests/H1AppLockUITests \
    -only-testing:HermesFleetAppUITests/RT4RosterEmptyStateUITests \
    -only-testing:HermesFleetAppUITests/RT4FormSaveFailureUITests \
    -only-testing:HermesFleetAppUITests/RT4VoiceOverUITests \
    -only-testing:HermesFleetAppUITests/SplashUITests \
    -only-testing:HermesFleetAppUITests/P2GatewayFormDraftUITests \
    build test >/tmp/c1_xctest_ui.log 2>&1; then
  TLINE=$(grep -E 'Test Suite.*(passed|failed)' /tmp/c1_xctest_ui.log | tail -1)
  ok "xcodebuild DETERMINISTIC UI tests SUCCEEDED — $TLINE"
  grep -E 'Executed .* tests' /tmp/c1_xctest_ui.log | tail -1 | sed 's/^/  /'
else
  bad "xcodebuild DETERMINISTIC UI tests FAILED"
  grep -E 'error:|failed|Test Suite|Executed' /tmp/c1_xctest_ui.log | tail -25
fi

# --- 5. secrets scan (gitleaks) ----------------------------------------------
note "gitleaks detect"
if command -v gitleaks >/dev/null 2>&1 && gitleaks detect --source "$REPO" --no-banner >/tmp/c1_gitleaks.log 2>&1; then
  ok "gitleaks: no leaks found"
else
  bad "gitleaks FAILED"; tail -15 /tmp/c1_gitleaks.log
fi

# --- Summary ------------------------------------------------------------------
printf '\n=====================================\n'
printf 'C1 CI: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
