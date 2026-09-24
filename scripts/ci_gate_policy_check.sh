#!/bin/bash
# Static guard for the integration-safe-main contract in .github/workflows/ci.yml.
# Keep this intentionally dependency-free: it runs before package and simulator
# work and must also work on a clean checkout without a YAML parser installed.
#
# Dev Loop v2 contract: pull requests run a fast preflight whose UI component
# is a focused subset selected by scripts/c1_ui_preflight.sh; merge_group
# candidates run the complete five-shard C1 matrix. Main pushes run only the
# post-merge static/package/unit validation; the merge_group event is the sole
# UI authority. The required `CI Gate` check must fail closed in every
# topology: every expected dependency must report success, and the job that
# must not run for an event must be reported skipped. A skipped expected
# dependency, a failure, or a cancellation all fail the gate.
set -euo pipefail
cd "$(dirname "$0")/.."

WORKFLOW=".github/workflows/ci.yml"
[[ -f "$WORKFLOW" ]] || { echo "FAIL: missing $WORKFLOW" >&2; exit 1; }

require() {
  local needle="$1"
  local explanation="$2"
  if ! grep -Fq -- "$needle" "$WORKFLOW"; then
    echo "FAIL: $explanation" >&2
    exit 1
  fi
}

require "  merge_group:" "CI must run for merge-group candidates"
require "    types: [checks_requested]" "CI must respond to merge-group check requests"
require "  pull_request:" "CI must run for pull requests"
require "  push:" "CI must run after main advances"
require '  group: ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}' "CI concurrency must distinguish PR/main runs"
require "  cancel-in-progress: \${{ github.event_name != 'merge_group' }}" "merge-group checks must never be cancelled by concurrency"

# A required workflow must not disappear for docs-only or otherwise unmatched
# changes. Merge-group events also have their own trigger semantics, so do not
# reintroduce path filtering on this full gate.
if grep -Eq '^    paths:' "$WORKFLOW"; then
  echo "FAIL: the full CI Gate must not use trigger path filters" >&2
  exit 1
fi
if grep -Eq '^  cancel-in-progress: true$' "$WORKFLOW"; then
  echo "FAIL: merge-group validation must not use unconditional cancellation" >&2
  exit 1
fi

require "    name: CI Gate" "the aggregation job must remain named CI Gate"
require "    needs: [static-guards, packages, units, ui-shard, ui-preflight]" "both UI topologies must feed CI Gate"
require "    if: always()" "CI Gate must run even when a dependency fails or is skipped"
require 'echo "${{ toJSON(needs.*.result) }}"' "CI Gate must expose every dependency result"
require 'CI_GATE_EVENT_NAME: ${{ github.event_name }}' "CI Gate must pass the event topology to the executable evaluator"
require 'CI_GATE_STATIC_RESULT: ${{ needs.static-guards.result }}' "CI Gate must pass static result to the evaluator"
require 'CI_GATE_PACKAGES_RESULT: ${{ needs.packages.result }}' "CI Gate must pass package result to the evaluator"
require 'CI_GATE_UNITS_RESULT: ${{ needs.units.result }}' "CI Gate must pass unit result to the evaluator"
require 'CI_GATE_UI_SHARD_RESULT: ${{ needs.ui-shard.result }}' "CI Gate must pass UI matrix result to the evaluator"
require 'CI_GATE_UI_PREFLIGHT_RESULT: ${{ needs.ui-preflight.result }}' "CI Gate must pass preflight result to the evaluator"
require 'bash scripts/ci_gate_policy_eval.sh' "CI Gate must execute the fail-closed evaluator"
require "  ui-preflight:" "a PR-focused UI preflight job must remain present"
require "    if: github.event_name == 'pull_request'" "the UI preflight must be PR-only"
require 'run: bash scripts/c1_ui_preflight.sh --base "${{ github.event.pull_request.base.sha }}"' "the PR preflight must select from the pull request's changed files"
require "  ui-shard:" "the full UI matrix job must remain present"
require "    if: github.event_name == 'merge_group'" "the full UI matrix must run on merge groups only"
require "      fail-fast: false" "a failing UI shard must not cancel its siblings"
if ! awk '
  /^  ui-shard:$/ { in_ui_shard=1; next }
  /^  [[:alnum:]_-]+:$/ { if (in_ui_shard) exit }
  in_ui_shard && /^    timeout-minutes: 150$/ { found=1 }
  END { exit !found }
' "$WORKFLOW"; then
  echo "FAIL: the authoritative UI matrix must have a 150-minute ceiling" >&2
  exit 1
fi
require "        shard: [1, 2, 3, 4, 5]" "all deterministic UI shards must remain configured"
require "        shards: [5]" "the UI matrix must keep its five-shard split"
require "        run: bash scripts/ci_gate_policy_check.sh" "CI must verify its own integration policy"
require "        run: bash scripts/ci_gate_policy_contract_test.sh" "CI must execute event-specific CI Gate contract tests"
require "        run: bash scripts/c1_ui_preflight_test.sh" "CI must verify the preflight selector"

echo "PASS: CI Gate policy is merge-group aware, PR-preflight aware, and fail-closed across all C1 phases."
