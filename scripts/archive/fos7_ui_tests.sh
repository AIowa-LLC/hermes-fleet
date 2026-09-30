#!/bin/bash
# FOS-7 UI test lane — serial runs of the visually-affected suites
# (NEVER two xcodebuilds in one tree/sim — kAX cascade).
set -uo pipefail
cd "$(dirname "$0")/.."

DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'

# Suites touched by FOS-7: settings/accent migration, theme pills,
# dashboard glance, roster pills, health badges, kanban headers, detail.
CLASSES=(
  FleetSettingsAccentUITests
  FOS6ComponentDensityUITests
  FOS4TruthfulHomeUITests
  FOS5BotsGroupsChatsUITests
  U4DashboardUITests
  U5BotDetailUITests
  # H2HealthDashboardUITests is a LIVE-LAN suite (needs the 19121 forwarder
  # + real gateway creds via scripts/h2_uitest.sh); it fails identically on
  # the pristine baseline without that infra (/tmp/fos7_h2_pristine.log,
  # rc=65) — proven environmental, not an FOS-7 regression. Lane: h2_uitest.sh.
  RT4VoiceOverUITests
  RT4RosterEmptyStateUITests
  KanbanBoardUITests
)

FAILED=()
for cls in "${CLASSES[@]}"; do
  LOG="/tmp/fos7_ui_${cls}.log"
  echo "== $cls"
  if xcodebuild -project HermesFleetApp.xcodeproj \
      -scheme HermesFleetApp \
      -destination "$DEST" \
      "-only-testing:HermesFleetAppUITests/$cls" \
      -resultBundlePath "/tmp/fos7_ui_${cls}_$(date +%s).xcresult" \
      test >"$LOG" 2>&1; then
    grep -E "Executed .* tests" "$LOG" | tail -1
  else
    echo "FAIL: $cls (see $LOG)"
    grep -E "error:|Failing tests|Assertion Failure" "$LOG" | head -10
    FAILED+=("$cls")
  fi
done

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "FAILED SUITES: ${FAILED[*]}"
  exit 1
fi
echo "PASS: all FOS-7 UI suites green"
