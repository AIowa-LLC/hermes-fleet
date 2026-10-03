#!/bin/bash
# Dev Loop v3 — fast local development validation.
#
#   static guards -> simulator build -> package tests -> focused UI suites
#   (selected from the working diff vs the base ref; never the full matrix)
#
# Hosted pull-request and merge-group preflight use the same selection. The
# merge queue also runs the fixed critical smoke; the complete five-shard C1
# matrix is available in the separate manual/nightly regression lane. Use
# `make ci` for the broad local gate.
#
# Usage:
#   bash scripts/dev_check.sh [--base <ref>] [--skip-ui]
set -u
cd "$(dirname "$0")/.." || exit 1

BASE=""
SKIP_UI=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:?--base needs a value}"; shift ;;
    --skip-ui) SKIP_UI=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

# Local runs default to this worktree's own simulator (HF-<repo>-<id>) so parallel
# lanes never share a device; CI and HERMES_FLEET_LANE_SIM=0 keep the shared
# first-available-iPhone selection. HERMES_FLEET_SIM_UDID overrides both.
# Exported so the focused UI preflight inherits the same choice.
if [ -z "${HERMES_FLEET_LANE_SIM:-}" ]; then
  if [ "${CI:-}" = true ]; then HERMES_FLEET_LANE_SIM=0; else HERMES_FLEET_LANE_SIM=1; fi
fi
export HERMES_FLEET_LANE_SIM
. scripts/sim_destination.sh

FAIL=0
note() { printf '\n========== %s ==========\n' "$1"; }

note "1/4 static guards (xcodegen drift, boundaries, privacy, safety, gitleaks)"
bash scripts/c1_static.sh || FAIL=1

DEV_RESULTS=$(mktemp -d /tmp/hermes-dev-check.XXXXXX) || exit 1
echo "Dev-check evidence: $DEV_RESULTS"
note "2/4 simulator build + package tests (independent phases)"
SIM_DEST=""
resolve_sim_destination iphone || SIM_DEST=""
if [ -n "$SIM_DEST" ]; then
  sim_announce
  python3 scripts/dev_check_parallel.py --destination "$SIM_DEST" --results "$DEV_RESULTS" || FAIL=1
  tail -12 "$DEV_RESULTS/build.log"
else
  echo "  no simulator destination could be selected" >&2
  FAIL=1
  bash scripts/c1_packages.sh > "$DEV_RESULTS/packages.log" 2>&1 || FAIL=1
fi
note "3/4 package results"
cat "$DEV_RESULTS/packages.log"

note "4/4 focused UI preflight (changed-area selection; never the full matrix)"
if [ "$SKIP_UI" -eq 1 ]; then
  echo "  skipped (--skip-ui)"
elif [ -n "$BASE" ]; then
  bash scripts/c1_ui_preflight.sh --base "$BASE" || FAIL=1
else
  bash scripts/c1_ui_preflight.sh || FAIL=1
fi

printf '\n=====================================\n'
if [ "$FAIL" -eq 0 ]; then
  echo "dev-check: PASS"
  echo "Next: 'make test' for the hosted unit bundle (optional), physical-device dogfood via"
  echo "'bash scripts/u4_device.sh', then push and open the pull request."
  exit 0
fi
echo "dev-check: FAIL"
exit 1
