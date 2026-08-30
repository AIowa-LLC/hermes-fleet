#!/bin/bash
# L1 live gateway dogfood — PHASE 1 probe #9: Arch gateway surface
# (multi-gateway reachability): hermes gateway config/status, listening ports,
# /api/ws + ws-ticket reachability from the Mac. No secrets printed.
set -u

echo "=== L1 probe 9: Arch gateway (multi-gateway) ==="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

SSH="ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new <private-ssh-target>"

echo
echo "--- Arch gateway status ---"
$SSH 'hermes gateway status 2>/dev/null | head -12' 2>&1 | head -14

echo
echo "--- Arch gateway config section (gateway.* + api_server) ---"
$SSH 'grep -n -A 12 "^gateway:" ~/.hermes/config.yaml 2>/dev/null | head -30; echo "---"; grep -n -A 6 "api_server" ~/.hermes/config.yaml 2>/dev/null | head -20' 2>&1 | head -50

echo
echo "--- Arch listening ports (hermes) ---"
$SSH 'lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -iE "python|node|hermes" | head -15; echo "---ifconfig---"; ip -4 addr show 2>/dev/null | grep inet | head -8' 2>&1 | head -30

echo
echo "--- Arch /api/ws + ws-ticket reachability from Mac ---"
# Use hostname/IP from Arch
ARCH_IP=$($SSH 'hostname -I 2>/dev/null | awk "{print \$1}"' 2>/dev/null | tr -d '\r')
echo "  Arch primary IP: ${ARCH_IP:-unknown}"
if [ -n "$ARCH_IP" ]; then
  for P in "api/ws" "api/auth/ws-ticket" "api/auth/status"; do
    C=$(curl -s -m 3 -o /dev/null -w "%{http_code}" "http://$ARCH_IP:8642/$P" 2>/dev/null)
    echo "  http://$ARCH_IP:8642/$P -> $C"
  done
fi

echo
echo "=== Done ==="
