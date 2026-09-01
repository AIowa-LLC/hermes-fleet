#!/bin/bash
# P0-6 (t_9df93c29) local verification: splash crop + jitter fix.
#
# Defect (Tony dogfood build 2): (1) artwork cropped — the native
# LaunchScreen used scaleAspectFill and the in-app overlay used
# scaledToFill, but the artwork (941x1672, ratio 0.563) is WIDER than a
# ~19.5:9 phone screen (~0.46), so aspect-FILL is height-limited and crops
# ~18% of the artwork's width. (2) jitter at load — the two layers had
# different geometry at the handoff frame (cropped fill vs overflowing
# scaledToFill with a safe-area-dependent first layout), so the artwork
# visibly jumped when the system launch screen was dismissed.
#
# Fix: BOTH layers now render full-bleed dark background + aspect-FIT
# artwork centered on the full screen (identical geometry from the first
# frame; the artwork's edges are near-black so the letterbox bars are
# imperceptible). The only animation is the single opacity fade-out.
#
# This script reproduces the verification:
#   1. build-for-testing + SplashUITests (includes P0-6 geometry assertions:
#      frame aspect == asset aspect, full width, symmetric vertical bars)
#   2. unit bundle HermesFleetAppTests (includes SplashConfigurationTests)
#   3. live launch + screenshot + pixel-level letterbox verification
#   4. cold-launch video frame analysis (artwork static through the window)
set -euo pipefail
cd "$(dirname "$0")/../.."
WS="${P06_WS:-$(mktemp -d)}"
SIM="${P06_SIM:-iPhone 17 Pro Max}"
echo "=== 1. SplashUITests (geometry assertions) ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "platform=iOS Simulator,name=$SIM,OS=latest" \
  -derivedDataPath build/P06DerivedData \
  build-for-testing >/dev/null
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "platform=iOS Simulator,name=$SIM,OS=latest" \
  -derivedDataPath build/P06DerivedData \
  -only-testing:HermesFleetAppUITests/SplashUITests \
  test-without-building 2>&1 | grep -E "Test Case.*(passed|failed)|Executed .* tests" | tail -3
echo "=== 2. unit bundle ==="
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination "platform=iOS Simulator,name=$SIM,OS=latest" \
  -derivedDataPath build/P06DerivedData \
  -only-testing:HermesFleetAppTests \
  test-without-building 2>&1 | grep -E "Executed .* tests" | tail -1
echo "=== 3. live screenshot + letterbox pixel check ==="
bash scripts/p06/p06_live_screenshot.sh
echo "=== P0-6 verification complete ==="
