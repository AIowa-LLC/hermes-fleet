#!/bin/bash
# C1 iPad smoke — adaptive navigation, accessibility, orientation, and the
# deterministic room/recovery paths that must be usable before an RC build.
# This is a local/QA device-family check; the hosted CI matrix remains the
# authoritative merge-group gate.
set -euo pipefail

cd "$(dirname "$0")/.."

DESTINATION_NAME="${HERMES_FLEET_IPAD_DESTINATION:-iPad Pro 11-inch (M5)}"
DERIVED_DATA_PATH="${HERMES_FLEET_IPAD_DERIVED_DATA:-build/ipad-smoke}"

echo "iPad smoke destination: ${DESTINATION_NAME}"
echo "Derived data: ${DERIVED_DATA_PATH}"

xcodebuild \
  -project HermesFleetApp.xcodeproj \
  -scheme HermesFleetApp \
  -destination "platform=iOS Simulator,name=${DESTINATION_NAME}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -skipMacroValidation \
  -only-testing:HermesFleetAppUITests/U3TabNavigationUITests \
  -only-testing:HermesFleetAppUITests/FOS8AccessibilityUITests \
  test
