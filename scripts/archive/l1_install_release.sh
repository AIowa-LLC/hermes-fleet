#!/bin/bash
# L1 live gateway dogfood — PHASE 2 prep: install the Release build on the
# booted simulator and launch it, capturing the Gateways screen.
set -u
SIM="iPhone 17 Pro"
APP=build/DerivedDataL1/Build/Products/Release-iphonesimulator/HermesFleetApp.app
OUT=build/l1

mkdir -p "$OUT"

echo "=== L1 Phase 2 prep: install + launch Release app ==="
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b 2>/dev/null | tail -1 || true
echo "  booted: $(xcrun simctl list devices booted | grep -i booted | head -1)"

echo "  installing..."
xcrun simctl install "$SIM" "$APP" && echo "  installed OK"

echo "  launching..."
xcrun simctl launch "$SIM" com.aiowa.hermesfleet
sleep 4

echo "  capturing Gateways screen..."
xcrun simctl io "$SIM" screenshot "$OUT/l1-p2-release-gateways.png" && echo "  screenshot -> $OUT/l1-p2-release-gateways.png"

echo "=== Done ==="
