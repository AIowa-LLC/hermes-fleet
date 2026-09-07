#!/usr/bin/env bash
# h2_preflight.sh — H2: verify the LAN surface + cred + forwarder + booted sim
# prerequisites before the live-gateway UI test. Runs via `bash scripts/h2_preflight.sh`.
set -uo pipefail
cd "$(dirname "$0")/.."

LAN_HOST="${HERMES_FLEET_LAN_HOST:?Set HERMES_FLEET_LAN_HOST to YOUR gateway LAN host}"
LAN_PORT="${HERMES_FLEET_LAN_PORT:-9120}"
echo "=== gateway $LAN_HOST:$LAN_PORT ==="
if nc -z -w 3 "$LAN_HOST" "$LAN_PORT" 2>/dev/null; then
  echo "  UP (TCP connect ok)"
else
  echo "  DOWN — UI test cannot run; is hermes serve LAN surface alive?"
fi

echo "=== /tmp/hermes_lan_surface/.cred ==="
if [ -f /tmp/hermes_lan_surface/.cred ]; then
  perms=$(stat -f '%Lp' /tmp/hermes_lan_surface/.cred)
  echo "  present (mode $perms)"
  [ "$perms" = "600" ] && echo "  mode ok (0600)" || echo "  WARN: mode is $perms, expected 600"
else
  echo "  MISSING — UI test credential file absent"
fi

echo "=== forwarder 127.0.0.1:19121 ==="
if nc -z -w 2 127.0.0.1 19121 2>/dev/null; then
  echo "  UP (existing forwarder)"
else
  echo "  DOWN (h2_uitest.sh will start it)"
fi

echo "=== booted simulators ==="
xcrun simctl list devices booted | grep -E "iPhone|iPad" | head -5 || echo "  none booted (h2_uitest.sh will boot iPhone 17 Pro)"
