#!/bin/bash
# L1 live gateway dogfood — PHASE 2/3 prep checks.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== L1 prep: routing-safety rules + device + git ==="

echo
echo "--- GatewayID.isRoutingSafe definition ---"
grep -rn "isRoutingSafe\|routingSafe" "$REPO"/Packages/FleetCore/Sources/FleetCore/*.swift | head -10

echo
echo "--- GatewayID(endpoint:) derivation ---"
grep -rn "init(endpoint" "$REPO"/Packages/FleetCore/Sources/FleetCore/*.swift | head -5

echo
echo "--- connected device state ---"
xcrun devicectl list devices 2>/dev/null | grep -i "iphone" | head -5

echo
echo "--- git baseline ---"
cd "$REPO" && git log --oneline -1 && git status --short | head -20

echo "=== Done ==="
