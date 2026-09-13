#!/bin/bash
# Static guard for the integration-safe-main contract in .github/workflows/ci.yml.
# Keep this intentionally dependency-free: it runs before package and simulator
# work and must also work on a clean checkout without a YAML parser installed.
#
# Dev Loop v2 contract: pull requests run a fast preflight whose UI component
# is a focused subset selected by scripts/c1_ui_preflight.sh; merge_group
# candidates (and main pushes) run the complete five-shard C1 matrix. The
# required `CI Gate` check must fail closed in BOTH topologies: every expected
# dependency must report success, and the job that must not run for an event
# must be reported skipped (substituted validation is a topology failure, not
# extra safety). A skipped expected dependency, a failure, or a cancellation
# all fail the gate.
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
require 'test "${{ needs.static-guards.result }}" = "success"' "static guards must be fail-closed"
require 'test "${{ needs.packages.result }}" = "success"' "package tests must be fail-closed"
require 'test "${{ needs.units.result }}" = "success"' "hosted units must be fail-closed"
require 'if [[ "${{ github.event_name }}" == "pull_request" ]]; then' "CI Gate must branch on the event topology"
require 'test "${{ needs.ui-preflight.result }}" = "success"' "the PR UI preflight must be fail-closed"
require 'test "${{ needs.ui-shard.result }}" = "skipped"' "the full matrix must not substitute for the PR preflight"
require 'test "${{ needs.ui-shard.result }}" = "success"' "the full UI matrix must be fail-closed outside pull requests"
require 'test "${{ needs.ui-preflight.result }}" = "skipped"' "the PR preflight must not substitute for the full matrix"
require "  ui-preflight:" "a PR-focused UI preflight job must remain present"
require "    if: github.event_name == 'pull_request'" "the UI preflight must be PR-only"
require 'run: bash scripts/c1_ui_preflight.sh --base "${{ github.event.pull_request.base.sha }}"' "the PR preflight must select from the pull request's changed files"
require "  ui-shard:" "the full UI matrix job must remain present"
require "    if: github.event_name != 'pull_request'" "the full UI matrix must run on merge groups and main pushes"
require "      fail-fast: false" "a failing UI shard must not cancel its siblings"
require "        shard: [1, 2, 3, 4, 5]" "all deterministic UI shards must remain configured"
require "        shards: [5]" "the UI matrix must keep its five-shard split"
require "        run: bash scripts/ci_gate_policy_check.sh" "CI must verify its own integration policy"
require "        run: bash scripts/c1_ui_preflight_test.sh" "CI must verify the preflight selector"

echo "PASS: CI Gate policy is merge-group aware, PR-preflight aware, and fail-closed across all C1 phases."
