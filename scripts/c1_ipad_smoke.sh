#!/bin/bash
# C1 iPad smoke — adaptive navigation, accessibility, orientation, and the
# deterministic room/recovery paths that must be usable before an RC build.
# This is a local/QA device-family check; the hosted CI matrix remains the
# authoritative merge-group gate.
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED_DATA_PATH="${HERMES_FLEET_IPAD_DERIVED_DATA:-build/ipad-smoke}"

# Destination precedence lives in scripts/sim_destination.sh: explicit UDID
# (HERMES_FLEET_IPAD_SIM_UDID) or name (HERMES_FLEET_IPAD_DESTINATION), then the
# worktree's iPad lane simulator (HERMES_FLEET_LANE_SIM=1), then the default
# named iPad Pro.
. scripts/sim_destination.sh
resolve_sim_destination ipad

echo "iPad smoke destination: ${SIM_DEST#platform=iOS Simulator,} (${SIM_SELECTION})"
echo "Derived data: ${DERIVED_DATA_PATH}"

xcodebuild \
  -project HermesFleetApp.xcodeproj \
  -scheme HermesFleetApp \
  -destination "${SIM_DEST}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -skipMacroValidation \
  -only-testing:HermesFleetAppUITests/U3TabNavigationUITests \
  -only-testing:HermesFleetAppUITests/FOS8AccessibilityUITests \
  test
