#!/bin/bash
# L1 live gateway dogfood — confirm the exact auth wiring: where the U2 UI
# stores the credential (CredentialStoring/KeychainCredentialStore) vs where
# the authenticator reads it (TokenStoring/KeychainTokenStore) and how the
# ticket minter is constructed (sessionToken nil). Structural, not fixed.
set -u
REPO=~/code/hermes-fleet-ios

echo "=== L1 auth wiring confirmation (for findings) ==="

echo
echo "--- KeychainCredentialStore service name ---"
grep -n "serviceName" $REPO/Packages/FleetSecurity/Sources/FleetSecurity/KeychainCredentialStore.swift | head -3

echo
echo "--- KeychainTokenStore service name ---"
grep -n "serviceName" $REPO/Packages/FleetSecurity/Sources/FleetSecurity/KeychainTokenStore.swift | head -3

echo
echo "--- FleetServiceGraph: loopback authenticator reads TokenStoring; ticket minter sessionToken:nil ---"
grep -n -A 4 "case .loopbackToken:" $REPO/HermesFleetApp/FleetServiceGraph.swift | head -8
grep -n -A 6 "case .sessionToken, .bearerToken:" $REPO/HermesFleetApp/FleetServiceGraph.swift | head -10

echo
echo "--- GatewayAuthSheet.saveToken -> environment.saveCredential (CredentialStoring path) ---"
grep -n "saveCredential" $REPO/Packages/FleetUI/Sources/FleetUI/GatewayAuthSheet.swift | head

echo "=== Done ==="
