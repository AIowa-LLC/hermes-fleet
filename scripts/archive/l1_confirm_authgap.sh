#!/bin/bash
# Confirm the L1 authentication wiring between credential storage,
# token storage, authenticator construction, and the UI save path.
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR/.." && pwd)

echo "=== L1 auth wiring confirmation ==="

echo
echo "--- KeychainCredentialStore service name ---"
grep -n "serviceName" "$REPO/Packages/FleetSecurity/Sources/FleetSecurity/KeychainCredentialStore.swift" | head -3

echo
echo "--- KeychainTokenStore service name ---"
grep -n "serviceName" "$REPO/Packages/FleetSecurity/Sources/FleetSecurity/KeychainTokenStore.swift" | head -3

echo
echo "--- FleetServiceGraph: loopback authenticator and ticket construction ---"
grep -n -A 4 "case .loopbackToken:" "$REPO/HermesFleetApp/FleetServiceGraph.swift" | head -8
grep -n -A 6 "case .sessionToken, .bearerToken:" "$REPO/HermesFleetApp/FleetServiceGraph.swift" | head -10

echo
echo "--- GatewayAuthSheet.saveToken -> environment.saveCredential ---"
grep -n "saveCredential" "$REPO/Packages/FleetUI/Sources/FleetUI/GatewayAuthSheet.swift" | head
echo "=== Done ==="
