#!/bin/bash
# L1 live gateway dogfood — PHASE 1 probe: identify which ports serve the
# Hermes dashboard/WS surface, auth mode, and reachability from each address.
# No secrets are printed. Run: bash scripts/l1_probe_gateway.sh
set -u

echo "=== L1 probe: Hermes gateway surfaces (default profile) ==="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# Which PIDs are serving Hermes
echo
echo "--- Listening Hermes-related sockets ---"
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -Ei "python|hermes" | head -20 || true

# The default-profile gateway PID from earlier observation
GW_PID=$(pgrep -f "hermes.*gateway" | head -5)
echo
echo "--- gateway PIDs ---"
echo "${GW_PID:-none}"

# Probe each listening surface for the dashboard (which serves /api/ws)
for SURFACE in "127.0.0.1:9900" "127.0.0.1:8642" "<tailnet-ip>:8642" "<lan-ip>:8642"; do
  HOST="${SURFACE%%:*}"
  PORT="${SURFACE##*:}"
  echo
  echo "--- Probe $HOST:$PORT ---"
  # HTTP root (title/route hints), short timeout, follow nothing
  curl -s -m 3 -o /tmp/l1_root_$PORT.txt -w "HTTP %{http_code} -> %{url_effective}\n" \
    "http://$HOST:$PORT/" 2>&1 || echo "  (unreachable over HTTP)"
  if [ -s /tmp/l1_root_$PORT.txt ]; then
    # Only show non-secret title hints
    grep -ioE "<title>[^<]*</title>" /tmp/l1_root_$PORT.txt | head -3 || true
    head -c 200 /tmp/l1_root_$PORT.txt | tr -d '\n' | head -c 200; echo
  fi
done

echo
echo "=== Done (no secrets printed) ==="
