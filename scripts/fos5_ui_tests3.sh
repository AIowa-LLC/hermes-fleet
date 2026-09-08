#!/bin/bash
# FOS-5: remaining suites that touch Bot Detail (FOS2 skills entry + the
# conversation suites that enter through bot detail). Serial only.
set -euo pipefail
cd /tmp/hermes-fleet-active
DEST='platform=iOS Simulator,id=393F1335-2DB1-48BD-96B9-A38B1EA488A4'
CLASSES=(
  FOS2GatewayDetailUITests
  RT4VoiceOverUITests
  R9ApprovalBannerUITests
  R9ConversationToolingUITests
  U6ConversationSkinUITests
  R10AttachmentTrayUITests
  R10MessageReactionsUITests
  R10VoiceUITests
)
for cls in "${CLASSES[@]}"; do
  echo "=== $cls ==="
  xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" ENABLE_TESTABILITY=YES \
    -only-testing:HermesFleetAppUITests/$cls test > "/tmp/fos5_ui3_${cls}.log" 2>&1 \
    && echo "$cls PASS" || { echo "$cls FAIL"; grep -E "error:|Failing|Assertion" "/tmp/fos5_ui3_${cls}.log" | head -20; exit 1; }
done
echo ALL_PASS
