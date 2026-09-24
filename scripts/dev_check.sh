#!/bin/bash
# Dev Loop v2 — fast local development validation.
#
#   static guards -> simulator build -> package tests -> focused UI suites
#   (selected from the working diff vs the base ref; never the full matrix)
#
# The hosted pull-request preflight runs the same selection; the merge queue
# runs the complete five-shard C1 matrix as the authoritative integration
# gate. Use `make ci` for the broad local gate.
#
# Usage:
#   bash scripts/dev_check.sh [--base <ref>] [--skip-ui]
set -u
cd "$(dirname "$0")/.."

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

FAIL=0
note() { printf '\n========== %s ==========\n' "$1"; }

note "1/4 static guards (xcodegen drift, boundaries, privacy, safety, gitleaks)"
bash scripts/c1_static.sh || FAIL=1

note "2/4 simulator build"
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*//')
[ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
echo "  using simulator: $SIM_NAME"
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "platform=iOS Simulator,name=$SIM_NAME,OS=latest" \
  -derivedDataPath build/DevCheck -skipMacroValidation build || FAIL=1

note "3/4 package tests (host swift test)"
bash scripts/c1_packages.sh || FAIL=1

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
