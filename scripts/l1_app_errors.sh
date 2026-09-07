#!/bin/bash
# L1: capture the exact network/auth error the Release app produced when
# probing the live gateway. Uses simctl log show (no secrets printed).
set -u

echo "=== L1: app-side probe error capture ==="
xcrun simctl spawn booted log show --last 4m --style compact \
  --predicate 'process == "HermesFleetApp"' 2>/dev/null \
  | grep -iE "error|fail|ticket|auth|ws-ticket|ats|transport|offline|unreachable|connection|4401|AppTransport" \
  | head -40 || echo "  (no matching log lines)"

echo
echo "--- also check network layer (nw/CFNetwork) ---"
xcrun simctl spawn booted log show --last 4m --style compact \
  --predicate 'process == "HermesFleetApp" OR process == "CFNetwork"' 2>/dev/null \
  | grep -iE "AppTransport|-1022|tls|http://127|ws://|networkd|nw_connection" \
  | head -20 || echo "  (none)"
echo "=== Done ==="
