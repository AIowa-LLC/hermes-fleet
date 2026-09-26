#!/bin/bash
# C1 UI matrix runner — the canonical deterministic UI suite inventory.
#
# Usage:
#   scripts/c1_ui_matrix.sh --all                  # every suite, serially (local full C1)
#   scripts/c1_ui_matrix.sh --shard N --shards M   # shard N of M (CI parallel topology)
#   scripts/c1_ui_matrix.sh --classes "A B C"      # explicit deterministic suite subset (focused preflight)
#   scripts/c1_ui_matrix.sh --tests "A/testOne B/testTwo" # exact method-level subset
#   scripts/c1_ui_matrix.sh --list-classes         # print the deterministic CI class inventory
#   scripts/c1_ui_matrix.sh --audit                # print shard mapping + coverage proof, run nothing
#
# DESIGN NOTES (carried from c1_ci_validate.sh):
#  - Each suite runs as its OWN xcodebuild test invocation with a class-level
#    -only-testing selector, after one build-for-testing (P1-7 fix: never mix a bare-bundle selector with
#    class-level selectors in one invocation — xcodebuild silently drops the
#    bare bundle).
#  - The ENVIRONMENTAL live-gateway suites (real `hermes serve` / LAN /
#    tailnet) are intentionally NOT part of CI; they run locally.
#  - Deep shard assignment uses the release line's historical runtime weights.
#    Inventory and weights must cover every deterministic suite. Focused jobs
#    retain the v3 coverage-preserving selector and independent partitioner.
#  - --classes is used by the changed-area preflight, and --tests is used by
#    the critical merge smoke (scripts/c1_ui_preflight.sh and
#    scripts/c1_critical_smoke.sh, Dev Loop v3). Each selects a deterministic
#    SUBSET of this inventory and never forks it; the full five-shard matrix
#    remains available in the separate manual/nightly regression lane.
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"

# Canonical deterministic CI suites (bare class names; UITests suffix added
# at invocation). Order is historical and also breaks runtime-weight ties.
UI_CLASSES=(
  HermesFleetHappyPath HermesFleetReconnect P0_7SessionStateMachine
  S3CleartextWarning RT2RemovalAndEndpointSanitization
  RT4RosterEmptyState RT4FormSaveFailure RT4VoiceOver Splash
  P2GatewayFormDraft F2QRPairing U3TabNavigation SecondGeneration
  U4Dashboard U5BotDetail U6ConversationSkin U7GatewayQrLockSettings
  F3Onboarding F4FirstRunGate C2SetupPrompt KanbanBoard KanbanInteractive R9ApprovalBanner
  R9ConversationTooling R9ManagementPanes R9MemoryGraph R10AttachmentTray
  R10MessageReactions R10ProjectsBrowser R10Voice R10MemoryGraphEdit
  ReasoningSlider
  Issue4SlashSkill Issue5StreamingRichText
  # Registered retroactively (Build 41): the slash-parity merge (8e477fe)
  # landed SlashCommandParityUITests without its inventory row — the audit
  # caught the drift.
  SlashCommandParity
  ConversationCompactChrome
  FleetSettingsAccent BotRoutines RoomChat RoomLinkMentions
  FOS2GatewayDetail FOS3FourRootShell FOS4TruthfulHome
  FOS5BotsGroupsChats FOS6ComponentDensity
  FOS8Accessibility
  BotsPresenceSync
  # Build 43 (restore bot editing + consolidate navigation): new suite.
  B43NavigationEditing
  BotAvatarAppearance BotPetAvatar BotAvatarSources
  # Re-admitted 2026-09-10 (i16): the 2026-09-10 hosted failures were a
  # proven test-harness defect (cross-suite persisted-nav leakage, H7), fixed
  # by NAV_RESET hermeticity in H1AppLockUITests — not environmental.
  H1AppLock
  # Card D (Artifacts destination + inline chat media): deterministic
  # scripted-fleet suite (no live gateway).
  ArtifactsDestination
  # Card E (image-generation animation): deterministic scripted-fleet suite
  # (no live gateway; HERMES_FLEET_IMAGE_DEMO + …_HOLD_MS/…_FAIL knobs).
  ImageGenerationAnimation
  # Card B (Cron destination): deterministic scripted-fleet suite (no live
  # gateway; HERMES_FLEET_NAV_RESET hermetic launch) — registered
  # retroactively after the audit caught the drift.
  CronManagement
  # Cron tab (six-tab shell): all-machines home — sections, inline ops.
  CronTab
  # ADR-0011 (Settings restructure + About tab): new deterministic suite.
  FleetAbout
  # Dogfood r4 (unread dots + drawer-only search + chrome ink): new suite.
  FleetUnreadBadge
  # ADR-0012 (launch cache): cached-first cold launch.
  FleetLaunchCache
)

# C1 elapsed-runtime weights in tenths of a minute, in the same order as
# UI_CLASSES. Source: merge-group run 36006153435 (suite start to final
# PASS/FAIL marker, including retry overhead); suites not started or cut off
# by shard 5's timeout use the preceding complete matrix run with the observed
# shard-5 slowdown applied. Failed-suite retry time is intentionally retained
# as conservative headroom until clean runs provide better estimates.
UI_WEIGHT_TENTHS_OF_MINUTE=(
  149 101 182 104 145 40 38 41 24 91 66 105
  53 32 157 57 58 45 47 48 45 110 51 108
  123 38 60 82 71 76 83 92 86 55 390 120
  75 129 94 71 90 199 46 74 108 101 41 91
  73 60 65 47 114 150 223 55 62 43 33
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


# --- argument parsing --------------------------------------------------------
MODE=all; SHARD=1; SHARDS=5; CLASSES=""; TESTS=""; FAIL_FAST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE=all ;;
    --audit) MODE=audit ;;
    --shard) MODE=shard; SHARD="${2:?--shard needs a value}"; shift ;;
    --shards) SHARDS="${2:?--shards needs a value}"; shift ;;
    --classes) MODE=classes; CLASSES="${2:?--classes needs a value}"; shift ;;
    --tests) MODE=tests; TESTS="${2:?--tests needs a value}"; shift ;;
    --list-classes) MODE=listclasses ;;
    --fail-fast) FAIL_FAST=1 ;;
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
if [ "$MODE" = listclasses ]; then
  echo "${UI_CLASSES[*]}"
  exit 0
fi
if [ "$MODE" = classes ]; then
  [ -n "$CLASSES" ] || die "--classes needs at least one suite"
  for wanted in $CLASSES; do
    found=0
    for known in "${UI_CLASSES[@]}"; do
      if [ "$wanted" = "$known" ]; then found=1; break; fi
    done
    [ "$found" -eq 1 ] || die "--classes entry is not a deterministic CI suite: $wanted"
  done
fi
if [ "$MODE" = tests ]; then
  [ -n "$TESTS" ] || die "--tests needs at least one Class/testMethod selector"
  for selector in $TESTS; do
    case "$selector" in
      */*) ;;
      *) die "--tests entry must be Class/testMethod: $selector" ;;
    esac
    cls="${selector%%/*}"
    method="${selector#*/}"
    case "$selector" in *"/"*"/"*) die "--tests entry must contain one slash: $selector" ;; esac
    case "$method" in ''|*[!A-Za-z0-9_]*) die "invalid test method name: $method" ;; esac
    found=0
    for known in "${UI_CLASSES[@]}"; do
      if [ "$cls" = "$known" ]; then found=1; break; fi
    done
    [ "$found" -eq 1 ] || die "--tests class is not a deterministic CI suite: $cls"
    test_file="HermesFleetAppUITests/${cls}UITests.swift"
    [ -f "$test_file" ] || die "--tests source file not found: $test_file"
    grep -Eq "^[[:space:]]*func[[:space:]]+${method}\\(" "$test_file" \
      || die "--tests method not found in ${test_file}: ${method}"
  done
fi

# Build the same deterministic LPT plan for every mode, including --audit.
# The plan accepts a different shard count for local diagnosis, while CI uses
# the five bins configured in .github/workflows/ui-regression.yml.
build_shard_plan() {
  local raw index shard
  [ "${#UI_WEIGHT_TENTHS_OF_MINUTE[@]}" -eq "${#UI_CLASSES[@]}" ] \
    || die "runtime weights must cover every deterministic UI suite"
  raw=$(python3 - "$SHARDS" "${#UI_CLASSES[@]}" "${UI_WEIGHT_TENTHS_OF_MINUTE[@]}" <<'PY'
import sys

shard_count = int(sys.argv[1])
suite_count = int(sys.argv[2])
weights = [int(value) for value in sys.argv[3:]]
if shard_count < 1 or len(weights) != suite_count or any(weight <= 0 for weight in weights):
    raise SystemExit("invalid shard count or deterministic suite runtime weights")

loads = [0] * shard_count
assignments = [0] * suite_count
for index in sorted(range(suite_count), key=lambda item: (-weights[item], item)):
    shard = min(range(shard_count), key=lambda item: (loads[item], item))
    assignments[index] = shard + 1
    loads[shard] += weights[index]

for index, shard in enumerate(assignments):
    print(index, shard)
PY
) || die "could not build deterministic runtime-weighted shard plan"
  SHARD_FOR_INDEX=()
  SHARD_TOTALS=()
  for ((index = 0; index < SHARDS; index++)); do SHARD_TOTALS+=(0); done
  while read -r index shard; do
    [ -n "$index" ] || continue
    [ "$shard" -ge 1 ] && [ "$shard" -le "$SHARDS" ] \
      || die "runtime-weighted plan assigned an invalid shard"
    SHARD_FOR_INDEX[$index]=$shard
    SHARD_TOTALS[$((shard - 1))]=$((SHARD_TOTALS[shard - 1] + UI_WEIGHT_TENTHS_OF_MINUTE[index]))
  done <<< "$raw"
  [ "${#SHARD_FOR_INDEX[@]}" -eq "${#UI_CLASSES[@]}" ] \
    || die "runtime-weighted plan did not assign every deterministic suite exactly once"
}
build_shard_plan

shard_for_index() { echo "${SHARD_FOR_INDEX[$1]}"; }

audit  # every mode audits first — fail loudly before running anything

# --- select the suites for this invocation -----------------------------------
SELECTED=()
for i in "${!UI_CLASSES[@]}"; do
  case "$MODE" in
    all) SELECTED+=("${UI_CLASSES[$i]}") ;;
    shard) [ "$(shard_for_index "$i")" -eq "$SHARD" ] && SELECTED+=("${UI_CLASSES[$i]}") ;;
    classes) case " $CLASSES " in *" ${UI_CLASSES[$i]} "*) SELECTED+=("${UI_CLASSES[$i]}") ;; esac ;;
    tests)
      for selector in $TESTS; do
        [ "${selector%%/*}" = "${UI_CLASSES[$i]}" ] && { SELECTED+=("${UI_CLASSES[$i]}"); break; }
      done
      ;;
  esac
done

if [ "$MODE" = audit ]; then
  echo "shard mapping ($SHARDS shards, deterministic runtime-weighted LPT; historical load units are 0.1 minutes, not a new-run forecast):"
  for s in $(seq 1 "$SHARDS"); do
    printf '  shard %d (historical load %d.%d): ' "$s" \
      "$((SHARD_TOTALS[s - 1] / 10))" "$((SHARD_TOTALS[s - 1] % 10))"
    for i in "${!UI_CLASSES[@]}"; do
      [ "$(shard_for_index "$i")" -eq "$s" ] && printf '%s ' "${UI_CLASSES[$i]}"
    done
    echo
  done
  exit 0
fi

if [ "$MODE" = tests ]; then
  echo "selected method-level smoke tests: $TESTS"
fi

# --- resolve simulator --------------------------------------------------------
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
echo "  using simulator: $SIM_NAME"
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
DD="$REPO/build/C1Ui"
# SwiftStreamingMarkdown v0.7.0 transitively uses the reviewed Equatable
# macro. Headless CI has no Xcode UI step to approve that pinned macro, so
# explicitly bypass fingerprint validation; this does not bypass macro
# execution or package resolution.
XC=(-project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" -skipMacroValidation)
RETRY=(-retry-tests-on-failure -test-iterations 2 \
    -test-repetition-relaunch-enabled YES)

# --- run -----------------------------------------------------------------------
# Each invocation owns its evidence directory. Never delete another worker's
# xcresults or reuse global numbered log files.
RESULTS_ROOT=$(mktemp -d /tmp/hermes-c1-results.XXXXXX) || die "cannot create evidence directory"
echo "UI evidence: $RESULTS_ROOT"
{
  git rev-parse HEAD
  git status --short
  xcodebuild -version
  printf 'destination=%s\nmode=%s\n' "$DEST" "$MODE"
} > "$RESULTS_ROOT/provenance.log" 2>&1
# Build once, retain per-suite process isolation, and reuse the compiled test
# products. Missing/failed builds are fatal, never successful empty tests.
if ! xcodebuild "${XC[@]}" build-for-testing > "$RESULTS_ROOT/build.log" 2>&1; then
  tail -40 "$RESULTS_ROOT/build.log"
  die "build-for-testing failed; no UI tests executed"
fi
UI_FAIL=0; UI_TOTAL=0; N=0
for cls in "${SELECTED[@]}"; do
  if [ "$FAIL_FAST" -eq 1 ] && [ "$UI_FAIL" -gt 0 ]; then
    echo "UI-MATRIX: stopping after a blocking failure; remaining tests are NOT passed."
    break
  fi
  N=$((N+1)); out="$RESULTS_ROOT/xcodebuild_${N}_${cls}.log"
  full="HermesFleetAppUITests/${cls}UITests"
  bundle="$RESULTS_ROOT/${cls}UITests.xcresult"
  summary_file="$RESULTS_ROOT/${cls}.summary.json"
  tests_file="$RESULTS_ROOT/${cls}.tests.json"
  rm -rf "$bundle"
  rm -f "$summary_file" "$tests_file"
  printf 'C1 UI (%s) [%02d/%02d] %s ...\n' "$MODE" "$N" "${#SELECTED[@]}" "$full"
  only_testing=()
  expected_cases=()
  if [ "$MODE" = tests ]; then
    for selector in $TESTS; do
      [ "${selector%%/*}" = "$cls" ] || continue
      method="${selector#*/}"
      only_testing+=("-only-testing:${full}/${method}")
      expected_cases+=("$method()")
    done
    [ "${#only_testing[@]}" -gt 0 ] || die "no method selectors resolved for $cls"
  else
    only_testing+=("-only-testing:$full")
  fi
  if ! xcodebuild "${XC[@]}" "${RETRY[@]}" -resultBundlePath "$bundle" "${only_testing[@]}" test-without-building >"$out" 2>&1; then
    UI_FAIL=$((UI_FAIL+1)); printf 'FAIL  UI %s FAILED or incomplete\n' "$cls"
    grep -E 'error:|failed|Executed|Test Suite' "$out" | tail -20; continue
  fi
  if [ ! -d "$bundle" ]; then
    UI_FAIL=$((UI_FAIL+1)); printf 'FAIL  UI %s INCOMPLETE: missing xcresult\n' "$cls"; continue
  fi
  xcrun xcresulttool get test-results summary --path "$bundle" --compact >"$summary_file" 2>/dev/null || true
  xcrun xcresulttool get test-results tests --path "$bundle" --compact >"$tests_file" 2>/dev/null || true
  parser_args=(
    --summary "$summary_file"
    --tests "$tests_file"
    --requested "${cls}UITests"
  )
  if [ "$MODE" = tests ]; then
    for expected_case in "${expected_cases[@]}"; do
      parser_args+=(--expect-case "$expected_case")
    done
  fi
  # The iPad orientation smoke is intentionally skipped by the iPhone CI
  # destination. Keep that exception explicit: any other skipped test still
  # fails closed in the parser.
  if [ "$cls" = "U3TabNavigation" ]; then
    parser_args+=(--allow-skipped "testIPadLandscapePreservesRootNavigation()")
  fi
  if ! parsed=$(python3 scripts/c1_xcresult_parse.py "${parser_args[@]}"); then
    UI_FAIL=$((UI_FAIL+1)); echo "FAIL  UI $cls result parser failed"; continue
  fi
  read -r count failures complete present recovered <<EOF
$parsed
EOF
  UI_TOTAL=$((UI_TOTAL+count))
  if [ "$present" -eq 1 ] && [ "$count" -gt 0 ] && [ "$failures" -eq 0 ] && [ "$complete" -eq 1 ]; then
    if [ "$recovered" -gt 0 ]; then
      printf 'FLAKE_RECOVERED  UI %s — recovered=%d final-result=passed\n' "$cls" "$recovered"
    fi
    printf 'PASS  UI %s — executed=%d failed=%d\n' "$cls" "$count" "$failures"
  else
    UI_FAIL=$((UI_FAIL+1))
    printf 'FAIL  UI %s INCOMPLETE or FAILED: executed=%s failed=%s complete=%s selector=%s\n' "$cls" "$count" "$failures" "$complete" "$present"
  fi
done
printf 'UI MATRIX (%s): suites=%d tests=%d FAIL=%d\n' "$MODE" "${#SELECTED[@]}" "$UI_TOTAL" "$UI_FAIL"
[ "$UI_FAIL" -eq 0 ] || exit 1
exit 0
