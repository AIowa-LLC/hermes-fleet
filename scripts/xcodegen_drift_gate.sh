#!/bin/bash
# xcodegen drift gate — `project.yml` is authoritative; the committed
# HermesFleetApp.xcodeproj/project.pbxproj must be exactly what
# `xcodegen generate` produces.
#
# Invariant:
#   1. modify project.yml
#   2. run `xcodegen generate`
#   3. commit both
#   NEVER hand-edit HermesFleetApp.xcodeproj/project.pbxproj.
#
# Usage: bash scripts/xcodegen_drift_gate.sh [--check]
#   --check  regenerate into a temp comparison without touching the working
#            tree files' mtimes is NOT possible with xcodegen (it always
#            writes); instead we regenerate, diff, and restore via git when
#            clean-check mode is requested. Default mode regenerates in
#            place and fails when `git diff --exit-code` reports drift.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "FAIL: xcodegen not found on PATH." >&2
  exit 2
fi

# Regenerate the project from project.yml.
xcodegen generate >/tmp/xcodegen_drift_gate.log 2>&1 || {
  echo "FAIL: xcodegen generate failed:" >&2
  tail -5 /tmp/xcodegen_drift_gate.log >&2
  exit 2
}

# The committed project must match the regenerated output exactly.
if git diff --exit-code -- HermesFleetApp.xcodeproj; then
  echo "PASS: HermesFleetApp.xcodeproj matches project.yml (no drift)."
  exit 0
else
  echo "FAIL: HermesFleetApp.xcodeproj is out of sync with project.yml." >&2
  echo "      Fix: edit project.yml (never the .pbxproj), then run 'xcodegen generate'" >&2
  echo "      and commit BOTH files together." >&2
  exit 1
fi
