#!/bin/bash
# L1: ATS-vs-auth discriminator. If ATS blocked http://127.0.0.1, the app log
# shows "App Transport Security has blocked a cleartext HTTP" / -1022.
set -u
WORK="${HERMES_FLEET_LIVE_WORKDIR:-${TMPDIR:-/tmp}/hermes-fleet-live}"

echo "=== L1: ATS signature hunt ==="
xcrun simctl spawn booted log show --last 10m 2>/dev/null \
  | grep -iE "App Transport|cleartext|has blocked|-1022|ATS" \
  | head -10 || echo "  (no ATS block signature)"
echo "  exit: no ATS block found = loopback cleartext is ATS-exempt (expected)"

echo
echo "=== confirm serve received zero WS/auth requests during the UI probe ==="
echo "  (serve log line count:)"
wc -l "$WORK/serve-persist.log" 2>/dev/null
echo "  (serve log content:)"
cat "$WORK/serve-persist.log" 2>/dev/null
echo "=== Done ==="
