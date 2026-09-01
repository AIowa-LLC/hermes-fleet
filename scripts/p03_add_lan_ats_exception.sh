#!/bin/bash
# t_c4a93ba8 P0-3: ATS exception for LAN gateway host <lan-ip>.
#
# DEFECT: iOS ATS silently blocks cleartext HTTP to raw LAN IPs.
# NSAllowsLocalNetworking only covers .local/bonjour names, NOT raw IPs, so
# http://<lan-ip>:9120 fails client-side while the backend is healthy.
#
# FIX: add <lan-ip> to NSExceptionDomains in HermesFleetApp/Info.plist
# (NSExceptionAllowsInsecureHTTPLoads=true, NSIncludesSubdomains=false),
# keeping the existing Tailscale <tailnet-ip> entry.
#
# The plist is a SOURCE file (INFOPLIST_FILE in project.yml); no xcodegen
# regen required. The B2 cleartext-warning flow is a Swift-side
# PrivateNetworkClassifier concern, untouched by ATS config.
#
# TOOLING: script file + bash only. No secrets.
set -euo pipefail
cd "$(dirname "$0")/.."
PLIST="HermesFleetApp/Info.plist"

if ! grep -q '<key><tailnet-ip></key>' "$PLIST"; then
  echo "FAIL: existing Tailscale ATS entry missing — abort, do not silently drop it" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSExceptionDomains:<lan-ip> dict' "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSExceptionDomains:<lan-ip>:NSExceptionAllowsInsecureHTTPLoads bool true' "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSExceptionDomains:<lan-ip>:NSIncludesSubdomains bool false' "$PLIST" 2>/dev/null || true
# re-assert values in case keys pre-existed with wrong values
/usr/libexec/PlistBuddy -c 'Set :NSAppTransportSecurity:NSExceptionDomains:<lan-ip>:NSExceptionAllowsInsecureHTTPLoads true' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :NSAppTransportSecurity:NSExceptionDomains:<lan-ip>:NSIncludesSubdomains false' "$PLIST"

plutil -lint "$PLIST"
echo "--- ATS dict after edit ---"
plutil -extract NSAppTransportSecurity xml1 -o - "$PLIST"
echo "--- invariants ---"
grep -c '<key><tailnet-ip></key>' "$PLIST" | xargs -I{} echo "tailscale entries: {}"
grep -c '<key><lan-ip></key>' "$PLIST" | xargs -I{} echo "lan entries: {}"
