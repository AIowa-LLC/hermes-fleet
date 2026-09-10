#!/bin/bash
# Static guard for the integration-safe-main contract in .github/workflows/ci.yml.
# Keep this intentionally dependency-free: it runs before package and simulator
# work and must also work on a clean checkout without a YAML parser installed.
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

# A required workflow must not disappear for docs-only or otherwise unmatched
# changes. Merge-group events also have their own trigger semantics, so do not
# reintroduce path filtering on this full gate.
if grep -Eq '^    paths:' "$WORKFLOW"; then
  echo "FAIL: the full CI Gate must not use trigger path filters" >&2
  exit 1
fi

require "    name: CI Gate" "the aggregation job must remain named CI Gate"
require "    needs: [static-guards, packages, units, ui-shard]" "all C1 phases must feed CI Gate"
require "    if: always()" "CI Gate must run even when a dependency fails or is skipped"
require 'echo "${{ toJSON(needs.*.result) }}"' "CI Gate must expose every dependency result"
require 'test "${{ needs.static-guards.result }}" = "success"' "static guards must be fail-closed"
require 'test "${{ needs.packages.result }}" = "success"' "package tests must be fail-closed"
require 'test "${{ needs.units.result }}" = "success"' "hosted units must be fail-closed"
require 'test "${{ needs.ui-shard.result }}" = "success"' "the UI matrix must be fail-closed"
require "        shard: [1, 2, 3, 4, 5]" "all deterministic UI shards must remain configured"
require "        run: bash scripts/ci_gate_policy_check.sh" "CI must verify its own integration policy"

echo "PASS: CI Gate policy is merge-group aware and fail-closed across all C1 phases."
