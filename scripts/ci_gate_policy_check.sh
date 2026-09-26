#!/bin/bash
# Static guard for the Dev Loop v3 workflow and fail-closed CI Gate contract.
# Keep dependency-free so it runs before package and simulator work.
set -euo pipefail
cd "$(dirname "$0")/.."

CI_WORKFLOW=".github/workflows/ci.yml"
DEEP_WORKFLOW=".github/workflows/ui-regression.yml"
[[ -f "$CI_WORKFLOW" ]] || { echo "FAIL: missing $CI_WORKFLOW" >&2; exit 1; }
[[ -f "$DEEP_WORKFLOW" ]] || { echo "FAIL: missing $DEEP_WORKFLOW" >&2; exit 1; }

require_in() {
  local file="$1"
  local needle="$2"
  local explanation="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $explanation" >&2
    exit 1
  fi
}

# The required merge workflow remains present on every relevant event and
# merge-group checks cannot be cancelled or disappear behind path filters.
require_in "$CI_WORKFLOW" "  merge_group:" "CI must run for merge-group candidates"
require_in "$CI_WORKFLOW" "    types: [checks_requested]" "CI must respond to merge-group check requests"
require_in "$CI_WORKFLOW" "  pull_request:" "CI must run for pull requests"
require_in "$CI_WORKFLOW" "  push:" "CI must run after main advances"
require_in "$CI_WORKFLOW" '  group: ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}' "CI concurrency must distinguish PR/main runs"
require_in "$CI_WORKFLOW" "  cancel-in-progress: \${{ github.event_name != 'merge_group' }}" "merge-group checks must never be cancelled by concurrency"
if grep -Eq '^    paths:' "$CI_WORKFLOW"; then
  echo "FAIL: the required CI Gate must not use trigger path filters" >&2
  exit 1
fi

# The required check name stays stable for the repository's GitHub ruleset.
require_in "$CI_WORKFLOW" "    name: CI Gate" "the required aggregate must remain named CI Gate"
require_in "$CI_WORKFLOW" "    needs: [static-guards, packages, units, ui-preflight, critical-smoke]" "all required merge validation jobs must feed CI Gate"
require_in "$CI_WORKFLOW" "    if: always()" "CI Gate must run even when a dependency fails or is skipped"
require_in "$CI_WORKFLOW" 'CI_GATE_EVENT_NAME: ${{ github.event_name }}' "CI Gate must pass the event topology"
require_in "$CI_WORKFLOW" 'CI_GATE_STATIC_RESULT: ${{ needs.static-guards.result }}' "CI Gate must pass static result"
require_in "$CI_WORKFLOW" 'CI_GATE_PACKAGES_RESULT: ${{ needs.packages.result }}' "CI Gate must pass package result"
require_in "$CI_WORKFLOW" 'CI_GATE_UNITS_RESULT: ${{ needs.units.result }}' "CI Gate must pass unit result"
require_in "$CI_WORKFLOW" 'CI_GATE_UI_PREFLIGHT_RESULT: ${{ needs.ui-preflight.result }}' "CI Gate must pass focused UI result"
require_in "$CI_WORKFLOW" 'CI_GATE_CRITICAL_SMOKE_RESULT: ${{ needs.critical-smoke.result }}' "CI Gate must pass critical smoke result"
require_in "$CI_WORKFLOW" 'bash scripts/ci_gate_policy_eval.sh' "CI Gate must execute the fail-closed evaluator"
if grep -Fq 'ui-shard' "$CI_WORKFLOW"; then
  echo "FAIL: the full UI matrix must not be a dependency of the required CI Gate" >&2
  exit 1
fi

# Focused UI runs on PR changes and exact merge candidates. Critical journeys
# run only on the merge-group candidate, alongside changed-area selection.
require_in "$CI_WORKFLOW" "  ui-preflight:" "a changed-area UI preflight must remain present"
require_in "$CI_WORKFLOW" "    if: github.event_name == 'pull_request' || github.event_name == 'merge_group'" "preflight must run on PR and merge-group events"
require_in "$CI_WORKFLOW" 'run: bash scripts/c1_ui_preflight.sh --base "${{ github.event.pull_request.base.sha || github.event.merge_group.base_sha }}" --shard "${{ matrix.shard }}" --shards 12' "preflight must diff against the event's base commit"
require_in "$CI_WORKFLOW" "  critical-smoke:" "a critical UI smoke job must remain present"
require_in "$CI_WORKFLOW" "    if: github.event_name == 'merge_group'" "critical smoke must run against merge-group candidates"
require_in "$CI_WORKFLOW" "run: bash scripts/c1_critical_smoke.sh" "critical smoke must use the deterministic suite selector"
require_in "$CI_WORKFLOW" "if: always()" "critical smoke diagnostics must be retained on success and failure"

require_in "$CI_WORKFLOW" '        shard: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]' "focused coverage must retain all twelve smaller partitions"
require_in "$CI_WORKFLOW" '      max-parallel: 6' "focused concurrency must stay bounded"
require_in "$CI_WORKFLOW" '      fail-fast: true' "focused matrix must fail fast"
require_in "$CI_WORKFLOW" 'python3 scripts/c1_ui_runner_contract_test.py' "CI must exercise the runner and partition contracts"
require_in "$CI_WORKFLOW" 'python3 scripts/c1_xcresult_parse_test.py' "CI must exercise the fail-closed result parser"
if grep -Fq 'MAX_FOCUSED_CLASSES' scripts/c1_ui_preflight.sh; then
  echo "FAIL: oversized changed-area coverage must not be dropped" >&2; exit 1
fi
SMOKE_TESTS="$(bash scripts/c1_critical_smoke.sh --list-tests)"
EXPECTED_SMOKE_TESTS="F3Onboarding/testFreshInstallLandsOnOnboardingAsRootSurface U3TabNavigation/testBotsTabOpensFleetRoster HermesFleetHappyPath/testHappyPathGatewaysToConversationStreamedAnswer RoomChat/testHostedRoomOpenSendAndTranscriptRender"
LATEST_ROOM_TEST="FOS8Accessibility/testGroupConversationOpensAtLatestWithDeepHistory"
if grep -Eq '^[[:space:]]*func[[:space:]]+testGroupConversationOpensAtLatestWithDeepHistory\(' HermesFleetAppUITests/FOS8AccessibilityUITests.swift; then
  EXPECTED_SMOKE_TESTS="$EXPECTED_SMOKE_TESTS $LATEST_ROOM_TEST"
fi
[ "$SMOKE_TESTS" = "$EXPECTED_SMOKE_TESTS" ] || {
  echo "FAIL: critical smoke must match the reviewed method-level journey set" >&2
  exit 1
}
EXPECTED_SMOKE_COUNT="$(printf '%s\n' "$EXPECTED_SMOKE_TESTS" | wc -w | tr -d ' ')"
[ "$(printf '%s\n' "$SMOKE_TESTS" | wc -w | tr -d ' ')" -eq "$EXPECTED_SMOKE_COUNT" ] || {
  echo "FAIL: critical smoke must stay at the reviewed bounded size" >&2
  exit 1
}
KNOWN_CLASSES="$(bash scripts/c1_ui_matrix.sh --list-classes)"
for selector in $SMOKE_TESTS; do
  cls="${selector%%/*}"
  method="${selector#*/}"
  case " $KNOWN_CLASSES " in
    *" $cls "*) : ;;
    *) echo "FAIL: critical smoke references unknown suite $cls" >&2; exit 1 ;;
  esac
  if ! grep -Eq "^[[:space:]]*func[[:space:]]+${method}\\(" "HermesFleetAppUITests/${cls}UITests.swift"; then
    echo "FAIL: critical smoke references missing test ${cls}/${method}" >&2
    exit 1
  fi
done

# The complete five-shard inventory stays available in a separate deep lane,
# triggered manually for an RC or nightly from the default branch.
require_in "$DEEP_WORKFLOW" "  workflow_dispatch:" "full UI regression must be manually runnable against a selected source ref"
require_in "$DEEP_WORKFLOW" "  schedule:" "full UI regression must have a nightly schedule"
require_in "$DEEP_WORKFLOW" "    timeout-minutes: 150" "full UI shards must retain recovery margin for the 59-suite weighted inventory"
require_in "$DEEP_WORKFLOW" "        shard: [1, 2, 3, 4, 5]" "all five full-matrix shards must remain"
require_in "$DEEP_WORKFLOW" "        shards: [5]" "the full matrix must retain its five-way split"
require_in "$DEEP_WORKFLOW" "run: bash scripts/c1_ui_matrix.sh --shard" "deep validation must execute the canonical full inventory"
require_in "$DEEP_WORKFLOW" "if: always()" "deep validation must retain artifacts after success and failure"
require_in "$DEEP_WORKFLOW" "actions/upload-artifact@v4" "deep validation must publish xcresult diagnostics"
require_in "$DEEP_WORKFLOW" "name: Full UI Regression Gate" "deep validation must report one aggregate result"

# Preserve the existing package/unit/static checks and their contract tests.
require_in "$CI_WORKFLOW" "        run: bash scripts/ci_gate_policy_check.sh" "CI must validate its own workflow topology"
require_in "$CI_WORKFLOW" "        run: bash scripts/ci_gate_policy_contract_test.sh" "CI must execute gate contract tests"
require_in "$CI_WORKFLOW" "        run: bash scripts/c1_ui_preflight_test.sh" "CI must test the changed-area selector"

echo "PASS: Dev Loop v3 CI Gate is fail-closed, requires focused plus critical merge UI, and keeps the full matrix in a separate deep lane."
