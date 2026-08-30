#!/bin/bash
# t_f54b722e: Mac-side probe of the exact providers endpoint the app hangs on,
# plus the LAN + tailnet surface state. Read-only, no secrets.
set -u
echo "=== Mac-side /api/auth/providers probes (no auth) ==="
for H in <tailnet-ip> <lan-ip> 127.0.0.1; do
  echo "--- $H:9120 ---"
  curl -sS -m 6 -o /tmp/t2_providers_$H.json -w "  HTTP %{http_code} redirect=%{redirect_url} time=%{time_total}s\n" "http://$H:9120/api/auth/providers" 2>&1 || echo "  FAILED: $?"
done
echo "=== providers payload (tailnet, first 200 bytes) ==="
head -c 300 /tmp/t2_providers_<tailnet-ip>.json 2>/dev/null; echo
echo "=== lsof :9120 ==="
lsof -nP -iTCP:9120 -sTCP:LISTEN 2>/dev/null | awk '{print $1,$2,$9}'
echo "=== END ==="
