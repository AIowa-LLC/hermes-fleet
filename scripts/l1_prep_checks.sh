#!/bin/bash
# L1 live gateway dogfood — PHASE 2/3 prep checks.
set -u

echo "=== L1 prep: routing-safety rules + device + git ==="

echo
echo "--- GatewayID.isRoutingSafe definition ---"
grep -rn "isRoutingSafe\|routingSafe" ~/code/hermes-fleet-ios/Packages/FleetCore/Sources/FleetCore/*.swift | head -10

echo
echo "--- GatewayID(endpoint:) derivation ---"
grep -rn "init(endpoint" ~/code/hermes-fleet-ios/Packages/FleetCore/Sources/FleetCore/*.swift | head -5

echo
echo "--- device unlock state (iPhone 16 Pro Max) ---"
xcrun devicectl list devices 2>/dev/null | grep -i "iphone" | head -5

echo
echo "--- git baseline ---"
cd ~/code/hermes-fleet-ios && git log --oneline -1 && git status --short | head -20

echo "=== Done ==="
