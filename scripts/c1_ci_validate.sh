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

# --- 1b. xcodegen drift gate --------------------------------------------------
# project.yml is authoritative: the committed .pbxproj must be exactly the
# regenerated output. Catches hand-edited project files and forgotten
# regenerations. Invariant: edit project.yml -> `xcodegen generate` -> commit
# BOTH. NEVER hand-edit HermesFleetApp.xcodeproj/project.pbxproj.
note "xcodegen drift gate (project.yml authoritative)"
if bash scripts/xcodegen_drift_gate.sh >/tmp/c1_drift.log 2>&1; then
  ok "xcodegen drift gate: committed project matches project.yml"
else
  bad "xcodegen DRIFT: HermesFleetApp.xcodeproj does not match project.yml"; tail -10 /tmp/c1_drift.log
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

# 4b. DETERMINISTIC scripted-fleet UI suites. Run each canonical class in
# bounded invocations so one slow simulator suite cannot hide progress or
# make the aggregate gate ambiguous. Keep this list identical to the former
# monolithic selector set.
UI_CLASSES=(
  HermesFleetHappyPathUITests HermesFleetReconnectUITests P0_7SessionStateMachineUITests
  S3CleartextWarningUITests RT2RemovalAndEndpointSanitizationUITests H1AppLockUITests
  RT4RosterEmptyStateUITests RT4FormSaveFailureUITests RT4VoiceOverUITests SplashUITests
  P2GatewayFormDraftUITests F2QRPairingUITests U3TabNavigationUITests SecondGenerationUITests
  U4DashboardUITests U5BotDetailUITests U6ConversationSkinUITests U7GatewayQrLockSettingsUITests
  F3OnboardingUITests C2SetupPromptUITests KanbanBoardUITests R9ApprovalBannerUITests
  R9ConversationToolingUITests R9ManagementPanesUITests R9MemoryGraphUITests R10AttachmentTrayUITests
  R10MessageReactionsUITests R10ProjectsBrowserUITests R10VoiceUITests R10MemoryGraphEditUITests
  FleetSettingsAccentUITests BotRoutinesUITests RoomChatUITests RoomLinkMentionsUITests
  FOS2GatewayDetailUITests FOS3FourRootShellUITests FOS4TruthfulHomeUITests
)
rm -rf /tmp/hermes-c1-results
mkdir -p /tmp/hermes-c1-results
UI_PASS=0; UI_FAIL=0; UI_TOTAL=0
for i in "${!UI_CLASSES[@]}"; do
  cls="${UI_CLASSES[$i]}"; n=$((i+1)); out="/tmp/c1_xctest_ui_${n}.log"
  bundle="/tmp/hermes-c1-results/${cls}.xcresult"
  rm -rf "$bundle"
  printf 'C1 UI [%02d/%02d] %s ...\n' "$n" "${#UI_CLASSES[@]}" "$cls"
  if ! xcodebuild "${XC[@]}" -resultBundlePath "$bundle" "-only-testing:HermesFleetAppUITests/$cls" build test >"$out" 2>&1; then
    UI_FAIL=$((UI_FAIL+1)); bad "UI $cls FAILED or incomplete"; grep -E 'error:|failed|Executed|Test Suite' "$out" | tail -20; continue
  fi
  if [ ! -d "$bundle" ]; then
    UI_FAIL=$((UI_FAIL+1)); bad "UI $cls INCOMPLETE: missing xcresult"; continue
  fi
  summary=$(xcrun xcresulttool get test-results summary --path "$bundle" --compact 2>/dev/null || true)
  tests=$(xcrun xcresulttool get test-results tests --path "$bundle" --compact 2>/dev/null || true)
  parsed=$(SUMMARY="$summary" TESTS="$tests" REQUESTED="$cls" python3 - <<'PY'
import json, os, sys
try:
    s=json.loads(os.environ["SUMMARY"]); t=json.loads(os.environ["TESTS"]); requested=os.environ["REQUESTED"]
except Exception:
    print("0 0 0 0"); sys.exit(0)
seen=[]
def walk(v):
    if isinstance(v, dict):
        if v.get("nodeType") == "Test Case": seen.append(v)
        for x in v.values(): walk(x)
    elif isinstance(v, list):
        for x in v: walk(x)
walk(t)
matched=[x for x in seen if x.get("nodeIdentifier", "").split("/")[-2:-1] == [requested]]
failures=sum(1 for x in matched if x.get("result") not in ("Passed", "Expected Failure"))
complete=(s.get("result") == "Passed" and s.get("totalTestCount", 0) > 0)
print(len(matched), failures, int(complete), int(bool(matched)))
PY
)
  read -r count failures complete present <<EOF
$parsed
EOF
  UI_TOTAL=$((UI_TOTAL+count))
  if [ "$present" -eq 1 ] && [ "$count" -gt 0 ] && [ "$failures" -eq 0 ] && [ "$complete" -eq 1 ]; then
    UI_PASS=$((UI_PASS+1)); printf 'C1 UI [%02d/%02d] %s PASS — executed=%d failed=%d\n' "$n" "${#UI_CLASSES[@]}" "$cls" "$count" "$failures"
  else
    UI_FAIL=$((UI_FAIL+1)); bad "UI $cls INCOMPLETE or FAILED: executed=$count failed=$failures complete=$complete selector=$present"
  fi
done
printf 'UI PASS=%d FAIL=%d TESTS=%d\n' "$UI_PASS" "$UI_FAIL" "$UI_TOTAL"
if [ "$UI_FAIL" -ne 0 ]; then bad "deterministic UI matrix failed"; fi

# --- 5. public-safety residue guard (Issue #2, Pass B) ------------------------
note "public-safety residue guard"
if bash scripts/public_safety_guard.sh >/tmp/c1_guard.log 2>&1; then
  ok "public-safety guard: tracked tree clean"
else
  bad "public-safety guard FAILED"; tail -20 /tmp/c1_guard.log
fi

# --- 6. secrets scan (gitleaks) ----------------------------------------------
note "gitleaks detect"
# Match CI's depth-1 checkout semantics: scan the TIP commit only. A local
# full-history scan also flags F2's known fixture-password noise in the
# superseded commit 5ed93e3 (files no longer contain those strings at HEAD);
# the tip-only scan is the same gate CI runs (operator CI-gate change,
# 2026-09-01: local run of this script IS the quality gate).
TIP_SHA=$(git -C "$REPO" rev-parse HEAD)
if command -v gitleaks >/dev/null 2>&1 && gitleaks detect --source "$REPO" --no-banner --log-opts="$TIP_SHA -1" >/tmp/c1_gitleaks.log 2>&1; then
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
