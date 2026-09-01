#!/bin/bash
# t_8a7f3dce (P0-7): quick gateway liveness probe — is the tailnet gateway's
# auth chain healthy right now? Mirrors t2_tailnet_probe.sh steps 1-3 only.
# Zero-print rule: .cred values are sourced and used but NEVER echoed.
set -u
umask 077
CRED=/tmp/hermes_lan_surface/.cred
[ -r "$CRED" ] || { echo "FATAL: $CRED missing"; exit 1; }
set -a; source "$CRED" 2>/dev/null; set +a
U="${username:-}"; P="${password:-}"
unset username password secret
[ -n "$U" ] && [ -n "$P" ] || { echo "FATAL: cred keys incomplete"; exit 1; }

WORK=/tmp/p07_probe
mkdir -p "$WORK"
BASE="http://<tailnet-ip>:9120"

code0=$(curl -s -m 6 -o /dev/null -w '%{http_code}' "$BASE/")
echo "[0] GET / -> $code0 (expect 302)"

code1=$(curl -s -m 6 -c "$WORK/jar" -o /dev/null -w '%{http_code}' \
  -H "Content-Type: application/json" \
  -d "{\"provider\":\"basic\",\"username\":\"$U\",\"password\":\"$P\"}" \
  "$BASE/auth/password-login")
echo "[1] password-login -> $code1 (expect 200)"
[ "$code1" = "200" ] || { echo "FATAL: login failed"; exit 1; }

code2=$(curl -s -m 6 -b "$WORK/jar" -o "$WORK/ticket" -w '%{http_code}' \
  -X POST "$BASE/api/auth/ws-ticket")
echo "[2] ws-ticket -> $code2 (expect 200)"
grep -q '"ticket"' "$WORK/ticket" && echo "    ticket present" || { echo "FATAL: no ticket"; exit 1; }
exit 0
