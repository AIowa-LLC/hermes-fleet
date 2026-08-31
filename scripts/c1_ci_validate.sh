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
#    RT2 removal/endpoint-sanitization and H1 app-lock suites) run in CI too.
#    The ENVIRONMENTAL live-gateway suites (L1*/P3Fix*/T2Fix*/H2 — need a real
#    `hermes serve` / Tony's home LAN / Tailscale) are intentionally NOT part
#    of CI: they run locally against the live gateway. This was the P1-7 fix:
#    previously `-only-testing:HermesFleetAppTests` excluded the ENTIRE UI
#    bundle, so navigation/composer/reconnect/form regressions could merge with
#    green CI.
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
# P1-7: select the unit bundle PLUS every DETERMINISTIC scripted-fleet UI suite
# (DEBUG build, no live gateway needed). The environmental live-gateway suites
# (L1*/P3Fix*/T2Fix*/H2) are NOT selected here — they stay gated/manual.
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" \
    -only-testing:HermesFleetAppTests \
    -only-testing:HermesFleetAppUITests/HermesFleetHappyPathUITests \
    -only-testing:HermesFleetAppUITests/HermesFleetReconnectUITests \
    -only-testing:HermesFleetAppUITests/S3CleartextWarningUITests \
    -only-testing:HermesFleetAppUITests/RT2RemovalAndEndpointSanitizationUITests \
    -only-testing:HermesFleetAppUITests/H1AppLockUITests \
    build test >/tmp/c1_xctest.log 2>&1; then
  TESTLINE=$(grep -E 'Test Suite.*(passed|failed)' /tmp/c1_xctest.log | tail -1)
  ok "xcodebuild build+test SUCCEEDED — $TESTLINE"
  grep -E 'Executed .* tests' /tmp/c1_xctest.log | tail -1 | sed 's/^/  /'
else
  bad "xcodebuild build+test FAILED"
  grep -E 'error:|failed|Test Suite' /tmp/c1_xctest.log | tail -25
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
