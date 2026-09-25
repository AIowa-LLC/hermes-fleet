#!/bin/bash
# Small deterministic UI journey set required for merge-group candidates.
# The full UI_CLASSES inventory remains in c1_ui_matrix.sh and runs from the
# manual/nightly full UI regression workflow.
set -euo pipefail
cd "$(dirname "$0")/.."

CRITICAL_SMOKE_TESTS=(
  F3Onboarding/testFreshInstallLandsOnOnboardingAsRootSurface
  U3TabNavigation/testBotsTabOpensFleetRoster
  HermesFleetHappyPath/testHappyPathGatewaysToConversationStreamedAnswer
  RoomChat/testHostedRoomOpenSendAndTranscriptRender
)

# The verified Build 87 tree adds a deep-history group-room regression case.
# Include it when the candidate carries that test. This makes the known room
# opening defect fail the merge candidate until its product fix is present,
# while keeping this runner compatible with the current Build 86 main tree.
LATEST_ROOM_TEST="FOS8Accessibility/testGroupConversationOpensAtLatestWithDeepHistory"
LATEST_ROOM_SOURCE="HermesFleetAppUITests/FOS8AccessibilityUITests.swift"
if [ -f "$LATEST_ROOM_SOURCE" ] && rg -q '^[[:space:]]*func[[:space:]]+testGroupConversationOpensAtLatestWithDeepHistory\(' "$LATEST_ROOM_SOURCE"; then
  CRITICAL_SMOKE_TESTS+=("$LATEST_ROOM_TEST")
fi

if [ "${1:-}" = "--list-tests" ]; then
  printf '%s\n' "${CRITICAL_SMOKE_TESTS[*]}"
  exit 0
fi
[ "$#" -eq 0 ] || { echo "usage: $0 [--list-tests]" >&2; exit 2; }

echo "Critical merge smoke journeys: ${CRITICAL_SMOKE_TESTS[*]}"
echo "  Fresh-install root, Bots roster, streamed conversation, hosted-room open/send, and latest-history room open when available."
bash scripts/c1_ui_matrix.sh --tests "${CRITICAL_SMOKE_TESTS[*]}"
