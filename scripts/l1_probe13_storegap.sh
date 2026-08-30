#!/bin/bash
# L1 live gateway dogfood — read _dashboard_public_hosts + check config for
# any public-url/dashboard section that would force the auth gate even on
# loopback. Also confirm the app credential-store split (Token vs Credential).
set -u
H=~/.hermes/hermes-agent/hermes_cli/web_server.py

echo "=== _dashboard_public_hosts (731) ==="
sed -n '731,753p' "$H"

echo
echo "=== config: dashboard / public_url / auth sections (default profile) ==="
grep -niE "^dashboard:|public_url|^  auth:|auth_required|nous_auth|hermes_session" ~/.hermes/config.yaml | head -20

echo
echo "=== config files that exist under profile homes ==="
ls -la ~/.hermes/profiles/*/config.yaml 2>/dev/null

echo
echo "=== app: does anything write KeychainTokenStore from UI? (no = finding) ==="
grep -rn "KeychainTokenStore\|TokenStoring\|saveToken" ~/code/hermes-fleet-ios/Packages/FleetUI ~/code/hermes-fleet-ios/HermesFleetApp 2>/dev/null | grep -v "\.build" | head
echo "--- UI writes only to CredentialStoring? ---"
grep -rn "saveCredential" ~/code/hermes-fleet-ios/Packages/FleetUI 2>/dev/null | grep -v "\.build" | head

echo "=== Done ==="
