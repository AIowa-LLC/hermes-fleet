#!/bin/bash
# t_8fd26e02 (Q1): restore the two live-gateway test surfaces for the
# live-gateway UI suites, per the P0-8 hermetic-launcher pattern.
#
# Root cause (R11-T1 QA): the LAN (<lan-ip>:9120) and tailnet
# (<tailnet-ip>:9120) dashboard listeners died, and macOS purged the /tmp
# fixture dirs (/tmp/hermes_lan_surface/.cred, /tmp/l1_live_test/.token,
# /tmp/f1_arch_gateway/.cred). The 19120/19121 TCP forwarders were never
# misconfigured — their targets are the correct LAN/tailnet surfaces.
# Fix: recreate the .cred fixture (fresh self-generated basic-auth pair; the
# old value is gone with /tmp and the gateway holds only a hash), relaunch the
# two listeners via scripts/p08_launch_gateways_hermetic.sh, then verify.
#
# The two endpoints must stay SEPARATE (memory b12): the login rate limit is
# 10/60s per client IP per surface; the suites exist for cookie-isolation
# coverage. Do NOT collapse 19120/19121 onto the shared :9119.
#
# Secret safety: creds are written 0600, never printed, never committed.
set -euo pipefail

REPO=<repo-root>
CRED_DIR=/tmp/hermes_lan_surface
CRED="$CRED_DIR/.cred"
LAN_IP=<lan-ip>
TAIL_IP=<tailnet-ip>
PORT=9120

cd "$REPO"

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "listeners already up on :$PORT — nothing to do"
  exit 0
fi

echo "=== [1/3] Recreate /tmp/hermes_lan_surface/.cred (fresh pair, 0600) ==="
mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"
if [ -f "$CRED" ]; then
  echo "  .cred already present — keeping existing credentials"
else
  USER_NAME="fleetbot"
  PASS=$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24)
  SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | head -c 32)
  umask 077
  printf 'username=%s\npassword=%s\nsecret=%s\n' "$USER_NAME" "$PASS" "$SECRET" > "$CRED"
  chmod 600 "$CRED"
  echo "  fresh cred written (user: $USER_NAME, password not printed)"
fi

echo "=== [2/3] Relaunch hermetic listeners via p08 launcher ==="
bash scripts/p08_launch_gateways_hermetic.sh

echo "=== [3/3] Verify both surfaces ==="
for ip in "$LAN_IP" "$TAIL_IP"; do
  code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$ip:$PORT/" || true)
  echo "  http://$ip:$PORT/ -> $code"
  [ "$code" != "000" ] || { echo "FAIL: $ip:$PORT unreachable"; exit 1; }
done

echo "=== [1/2] Restart stale forwarders 19120/19121 ==="
# Forwarders still listen but their upstream sockets die with the listeners;
# restart them so connections are freshly established.
for port in 19120 19121; do
  pids=$(lsof -nP -iTCP:$port -sTCP:LISTEN -t 2>/dev/null | sort -u || true)
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
done
sleep 1
python3 scripts/t2_tcp_forward.py 19120 "$TAIL_IP" "$PORT" >> /tmp/t2_fwd_19120.log 2>&1 &
echo "  forwarder 19120 -> $TAIL_IP:$PORT (pid $!)"
python3 scripts/t2_tcp_forward.py 19121 "$LAN_IP" "$PORT" >> /tmp/t2_fwd_19121.log 2>&1 &
echo "  forwarder 19121 -> $LAN_IP:$PORT (pid $!)"
sleep 1

echo "=== [2/2] End-to-end forwarder probes ==="
for port in 19120 19121; do
  code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port/" || echo 000)
  echo "  http://127.0.0.1:$port/ -> $code"
  [ "$code" != "000" ] || { echo "FAIL: forwarder $port not forwarding"; exit 1; }
done

echo "=== Q1 fixture restore complete ==="
