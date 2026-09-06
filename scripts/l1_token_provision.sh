#!/bin/bash
# L1: definitively check whether ANY production/UI path calls saveToken into
# the token store the loopback authenticator reads (TokenStoring). If not,
# loopback tokens can never be provisioned through the app — the finding.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== L1: token-store provisioning paths ==="
echo "--- saveToken callers (excluding store impls + tests) ---"
grep -rn "saveToken" "$REPO" --include="*.swift" | grep -v "\.build" | grep -v "func saveToken" | grep -v "Tests/" | head -20 || echo "  NONE — no caller"

echo
echo "--- InMemoryTokenStore / KeychainTokenStore usage in app graph ---"
grep -rn "KeychainTokenStore\|InMemoryTokenStore\|TokenStoring" "$REPO"/HermesFleetApp/*.swift | head

echo
echo "--- does the U2 UI ever call saveToken? (it uses saveCredential only) ---"
grep -rn "saveToken\|saveCredential" "$REPO"/Packages/FleetUI/Sources/FleetUI/*.swift | grep -v "\.build" | head -12

echo
echo "--- production auth for loopback: reads tokenStore (TokenStoring) ---"
grep -n -B2 -A6 "case .loopbackToken:" "$REPO"/HermesFleetApp/FleetServiceGraph.swift | head -14

echo "=== Done ==="
