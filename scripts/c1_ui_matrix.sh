#!/bin/bash
# C1 UI matrix runner — the canonical deterministic UI suite inventory.
#
# Usage:
#   scripts/c1_ui_matrix.sh --all                  # every suite, serially (local full C1)
#   scripts/c1_ui_matrix.sh --shard N --shards M   # shard N of M (CI parallel topology)
#   scripts/c1_ui_matrix.sh --audit                # print shard mapping + coverage proof, run nothing
#
# DESIGN NOTES (carried from c1_ci_validate.sh):
#  - Each suite runs as its OWN xcodebuild test invocation with a class-level
#    -only-testing selector (P1-7 fix: never mix a bare-bundle selector with
#    class-level selectors in one invocation — xcodebuild silently drops the
#    bare bundle).
#  - The ENVIRONMENTAL live-gateway suites (real `hermes serve` / LAN /
#    tailnet) are intentionally NOT part of CI; they run locally.
#  - Shard assignment is deterministic: suite at index i (canonical order
#    below) belongs to shard $(( i % SHARDS + 1 )). Adding a new suite class
#    to HermesFleetAppUITests makes --audit (and every shard run) FAIL LOUDLY
#    until it is added to UI_CLASSES (and, if it is environmental, to
#    ENVIRONMENTAL_CLASSES). No suite can silently disappear.
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"

# Canonical deterministic CI suites (bare class names; UITests suffix added
# at invocation). Order is historical; do not reorder without resharding.
UI_CLASSES=(
  HermesFleetHappyPath HermesFleetReconnect P0_7SessionStateMachine
  S3CleartextWarning RT2RemovalAndEndpointSanitization H1AppLock
  RT4RosterEmptyState RT4FormSaveFailure RT4VoiceOver Splash
  P2GatewayFormDraft F2QRPairing U3TabNavigation SecondGeneration
  U4Dashboard U5BotDetail U6ConversationSkin U7GatewayQrLockSettings
  F3Onboarding C2SetupPrompt KanbanBoard R9ApprovalBanner
  R9ConversationTooling R9ManagementPanes R9MemoryGraph R10AttachmentTray
  R10MessageReactions R10ProjectsBrowser R10Voice R10MemoryGraphEdit
  FleetSettingsAccent BotRoutines RoomChat RoomLinkMentions
  FOS2GatewayDetail FOS3FourRootShell FOS4TruthfulHome
  FOS5BotsGroupsChats FOS6ComponentDensity
  FOS8Accessibility
)

# Live-gateway/environmental suites — intentionally excluded from CI. They
# need real infrastructure and stay gated/manual/local.
ENVIRONMENTAL_CLASSES=(
  B1LiveBoardPicker BotChatTap BotRosterSlice2 F1TwoGatewayFleetLive
  H2HealthDashboard L1FixLiveGateway L1LiveGateway P0_7LiveTailnet
  P3FixLANGateway P3FixLoopbackGateway T2FixTailnetGateway
)

die() { printf 'UI-MATRIX FAIL: %s\n' "$1" >&2; exit 1; }

# --- coverage audit: every bundle class is either CI or environmental ------
audit() {
  local discovered required
  discovered=$(grep -hE '^(final )?class [A-Za-z0-9_]+UITests' HermesFleetAppUITests/*.swift \
    | sed -E 's/^(final )?class ([A-Za-z0-9_]+)UITests.*/\2/' | sort -u)
  required=$(printf '%s\n%s\n' "${UI_CLASSES[*]}" "${ENVIRONMENTAL_CLASSES[*]}" | tr ' ' '\n' | sort -u)
  if [ "$(printf '%s\n' "$discovered" | wc -l)" -ne "$(printf '%s\n' "$required" | wc -l)" ] \
     || [ -n "$(comm -3 <(printf '%s\n' "$discovered") <(printf '%s\n' "$required"))" ]; then
    echo "AUDIT FAILURE — bundle classes and the CI/environmental inventories diverge."
    echo "Classes in bundle but in NEITHER list (add to UI_CLASSES or ENVIRONMENTAL_CLASSES):"
    comm -23 <(printf '%s\n' "$discovered") <(printf '%s\n' "$required") | sed 's/^/  + /'
    echo "Listed but missing from bundle (rename/typo?):"
    comm -13 <(printf '%s\n' "$discovered") <(printf '%s\n' "$required") | sed 's/^/  - /'
    die "suite inventory out of sync with HermesFleetAppUITests sources"
  fi
  echo "audit: ${#UI_CLASSES[@]} CI suites + ${#ENVIRONMENTAL_CLASSES[@]} environmental suites = $(printf '%s\n' "$discovered" | wc -l | tr -d ' ') bundle classes — every class accounted for exactly once."
}

shard_for_index() { echo $(( $1 % SHARDS + 1 )); }

# --- argument parsing --------------------------------------------------------
MODE=all; SHARD=1; SHARDS=4
while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE=all ;;
    --audit) MODE=audit ;;
    --shard) MODE=shard; SHARD="${2:?--shard needs a value}"; shift ;;
    --shards) SHARDS="${2:?--shards needs a value}"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
case "$SHARDS" in ''|*[!0-9]*) die "--shards must be a positive integer" ;; esac
[ "$SHARDS" -ge 1 ] || die "--shards must be >= 1"
if [ "$MODE" = shard ]; then
  case "$SHARD" in ''|*[!0-9]*) die "--shard must be a positive integer" ;; esac
  [ "$SHARD" -ge 1 ] && [ "$SHARD" -le "$SHARDS" ] || die "--shard must be in 1..$SHARDS"
fi

audit  # every mode audits first — fail loudly before running anything

# --- select the suites for this invocation -----------------------------------
SELECTED=()
for i in "${!UI_CLASSES[@]}"; do
  case "$MODE" in
    all) SELECTED+=("${UI_CLASSES[$i]}") ;;
    shard) [ "$(shard_for_index "$i")" -eq "$SHARD" ] && SELECTED+=("${UI_CLASSES[$i]}") ;;
  esac
done

if [ "$MODE" = audit ]; then
  echo "shard mapping ($SHARDS shards, round-robin over canonical order):"
  for s in $(seq 1 "$SHARDS"); do
    printf '  shard %d: ' "$s"
    for i in "${!UI_CLASSES[@]}"; do
      [ "$(shard_for_index "$i")" -eq "$s" ] && printf '%s ' "${UI_CLASSES[$i]}"
    done
    echo
  done
  exit 0
fi

# --- resolve simulator --------------------------------------------------------
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
echo "  using simulator: $SIM_NAME"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
DD="$REPO/build/C1Ui"
XC=(-project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD")

# --- run -----------------------------------------------------------------------
rm -rf /tmp/hermes-c1-results
mkdir -p /tmp/hermes-c1-results
UI_FAIL=0; UI_TOTAL=0; N=0
for cls in "${SELECTED[@]}"; do
  N=$((N+1)); out="/tmp/c1_xctest_ui_${N}.log"
  full="HermesFleetAppUITests/${cls}UITests"
  bundle="/tmp/hermes-c1-results/${cls}UITests.xcresult"
  rm -rf "$bundle"
  printf 'C1 UI (%s) [%02d/%02d] %s ...\n' "$MODE" "$N" "${#SELECTED[@]}" "$full"
  if ! xcodebuild "${XC[@]}" -resultBundlePath "$bundle" "-only-testing:$full" build test >"$out" 2>&1; then
    UI_FAIL=$((UI_FAIL+1)); printf 'FAIL  UI %s FAILED or incomplete\n' "$cls"
    grep -E 'error:|failed|Executed|Test Suite' "$out" | tail -20; continue
  fi
  if [ ! -d "$bundle" ]; then
    UI_FAIL=$((UI_FAIL+1)); printf 'FAIL  UI %s INCOMPLETE: missing xcresult\n' "$cls"; continue
  fi
  summary=$(xcrun xcresulttool get test-results summary --path "$bundle" --compact 2>/dev/null || true)
  tests=$(xcrun xcresulttool get test-results tests --path "$bundle" --compact 2>/dev/null || true)
  parsed=$(SUMMARY="$summary" TESTS="$tests" REQUESTED="${cls}UITests" python3 - <<'PY'
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
    printf 'PASS  UI %s — executed=%d failed=%d\n' "$cls" "$count" "$failures"
  else
    UI_FAIL=$((UI_FAIL+1))
    printf 'FAIL  UI %s INCOMPLETE or FAILED: executed=%s failed=%s complete=%s selector=%s\n' "$cls" "$count" "$failures" "$complete" "$present"
  fi
done
printf 'UI MATRIX (%s): suites=%d tests=%d FAIL=%d\n' "$MODE" "${#SELECTED[@]}" "$UI_TOTAL" "$UI_FAIL"
[ "$UI_FAIL" -eq 0 ] || exit 1
exit 0
