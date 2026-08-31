#!/bin/bash
# t_eb5455f2: launch the installed app on the device via devicectl (P1-style
# launch evidence). Read-only.
set -u
UDID=<physical-device-id>
BUNDLE=com.aiowa.hermesfleet
echo "=== launch app on device ==="
xcrun devicectl device process launch --device "$UDID" "$BUNDLE" 2>&1 | tail -6
echo "launch exit: $?"
echo "=== app running? ==="
sleep 2
xcrun devicectl device info processes --device "$UDID" 2>&1 | grep -i "HermesFleet" | head -3 || echo "  (process check via devicectl filtered)"
echo "=== Done ==="
