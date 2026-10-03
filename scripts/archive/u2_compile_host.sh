#!/bin/bash
# U2 quick host-side compile pass — FleetCore + FleetNetworking + FleetUI.
# Used iteratively during development (fast, no simulator needed).
# Run with: bash scripts/u2_compile_host.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
FAIL=0

note() { printf '\n=== %s ===\n' "$1"; }

note "FleetCore build"
if (cd Packages/FleetCore && swift build) >/tmp/u2_core_build.log 2>&1; then
  echo "PASS  FleetCore builds"
else
  echo "FAIL  FleetCore build failed"; tail -30 /tmp/u2_core_build.log; FAIL=1
fi

note "FleetNetworking build"
if (cd Packages/FleetNetworking && swift build) >/tmp/u2_net_build.log 2>&1; then
  echo "PASS  FleetNetworking builds"
else
  echo "FAIL  FleetNetworking build failed"; tail -30 /tmp/u2_net_build.log; FAIL=1
fi

# NOTE: FleetUI is NOT host-built — it uses iOS-only list styles (.insetGrouped)
# and is validated via xcodebuild on the iOS Simulator (same as U1).

if [ "$FAIL" -gt 0 ]; then
  echo "HOST COMPILE: FAIL"
  exit 1
fi
echo "HOST COMPILE: PASS"
