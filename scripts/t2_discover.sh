#!/bin/bash
# t_f54b722e (T2): discover current fleet/tailnet/surface state before proving
# app-connects-over-tailnet. Read-only; no secrets printed.
set -u
echo "=== [1] date ==="
date '+%Y-%m-%d %H:%M:%S %Z'

echo "=== [2] tailscale status ==="
/Applications/Tailscale.app/Contents/MacOS/Tailscale status 2>/dev/null

echo "=== [3] tailscale ip -4 (this Mac) ==="
/Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4 2>/dev/null

echo "=== [4] listeners :9120 and :8642 ==="
lsof -nP -iTCP:9120 -sTCP:LISTEN 2>/dev/null | awk '{print $1, $2, $9}'
echo "---8642---"
lsof -nP -iTCP:8642 -sTCP:LISTEN 2>/dev/null | awk '{print $1, $2, $9}'

echo "=== [5] .cred shape (values NOT printed) ==="
CRED=/tmp/hermes_lan_surface/.cred
if [ -r "$CRED" ]; then
  u=$(sed -n 's/^username=//p' "$CRED")
  pw=$(sed -n 's/^password=//p' "$CRED")
  echo "  readable; username_len=${#u} password_len=${#pw}; mode=$(stat -f '%Lp' "$CRED")"
else
  echo "  MISSING/unreadable: $CRED"
fi

echo "=== [6] tailnet + LAN serve logs ==="
for f in /tmp/hermes_lan_surface/serve-tailnet.log /tmp/hermes_lan_surface/serve.log; do
  if [ -f "$f" ]; then
    echo "--- $f (tail -6) ---"
    tail -6 "$f" 2>/dev/null
  else
    echo "  (no such file: $f)"
  fi
done

echo "=== [7] tailnet ping to phone (100.119.54.110) — is iphone172 online? ==="
/Applications/Tailscale.app/Contents/MacOS/Tailscale ping -c 2 -timeout 3s 100.119.54.110 2>&1 | head -4 || true

echo "=== [8] connected iOS devices (devicectl) ==="
xcrun devicectl list devices 2>/dev/null | grep -iE "iPhone|available" | head -6
echo "=== Done ==="
