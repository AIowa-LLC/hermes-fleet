#!/bin/bash
# FOS-5 (t_41672ceb) local validation: the affected deterministic UI suites,
# run SERIALLY (one xcodebuild per class — kAX rule; never two xcodebuilds).
set -euo pipefail
cd /tmp/hermes-fleet-active
DEST='platform=iOS Simulator,id=393F1335-2DB1-48BD-96B9-A38B1EA488A4'
CLASSES=(
  FOS5BotsGroupsChatsUITests
  BotRosterSlice2UITests
  RoomChatUITests
  BotRoutinesUITests
  U5BotDetailUITests
  BotChatTapUITests
)
for cls in "${CLASSES[@]}"; do
  echo "=== $cls ==="
  xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" ENABLE_TESTABILITY=YES \
    -only-testing:HermesFleetAppUITests/$cls test > "/tmp/fos5_ui_${cls}.log" 2>&1 \
    && echo "$cls PASS" || { echo "$cls FAIL"; grep -E "error:|Failing|Assertion" "/tmp/fos5_ui_${cls}.log" | head -20; exit 1; }
done
echo ALL_PASS
