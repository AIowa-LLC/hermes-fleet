#!/bin/bash
# L1: hunt the exact app-side failure. Look for ATS (-1022 / "App Transport")
# or any URLSession/ticket/auth error the Release app logged during the probe.
set -u

echo "=== L1: exact app failure signature ==="
xcrun simctl spawn booted log show --last 8m --style compact \
  --predicate 'process == "HermesFleetApp"' 2>/dev/null \
  | grep -iE "App Transport|-1022|cleartext|NSURLError|ticket|4401|4403|ws-ticket|missingLoopback|AuthenticationError|unreachable|connectionFailed|transportFailure|URLSessionWebSocket" \
  | grep -vE "com.apple|xctest|XPC" | head -30 || echo "  (no match in app logs)"

echo
echo "=== broader: any HermesFleetApp OSLog lines (non-system) ==="
xcrun simctl spawn booted log show --last 8m --style compact \
  --predicate 'process == "HermesFleetApp" AND subsystem != "com.apple.*"' 2>/dev/null \
  | tail -40 || echo "  (none)"
echo "=== Done ==="
