#!/bin/bash
# L1 live gateway dogfood — PHASE 1 probe #4: full roster JSON on :9900,
# gateway state file, and locate any dashboard web_server instances.
# No secrets printed.
set -u

echo "=== L1 probe 4: gateway roster + dashboard instances ==="

echo
echo "--- 127.0.0.1:9900 full roster JSON ---"
curl -s -m 3 "http://127.0.0.1:9900/" 2>&1 | python3 -m json.tool 2>/dev/null || curl -s -m 3 "http://127.0.0.1:9900/" 2>&1 | head -c 3000

echo
echo "--- gateway_state.json ---"
python3 - <<'PYEOF' 2>/dev/null || cat ~/.hermes/gateway_state.json 2>/dev/null | head -c 3000
import json, os
p = os.path.expanduser("~/.hermes/gateway_state.json")
try:
    d = json.load(open(p))
    # redact any secret-ish keys
    def scrub(o, k=""):
        if isinstance(o, dict):
            return {kk: ("[REDACTED]" if any(s in kk.lower() for s in ("token","secret","key","auth","credential","password")) else scrub(v, kk)) for kk, v in o.items()}
        if isinstance(o, list):
            return [scrub(v, k) for v in o]
        return o
    print(json.dumps(scrub(d), indent=1)[:2500])
except Exception as e:
    print("state parse:", e)
PYEOF

echo
echo "--- dashboard / web_server instances ---"
ps -eo pid,command | grep -iE "web_server|dashboard|hermes_cli.main serve|hermes serve|tui_gateway" | grep -v grep | cut -c1-200 | head -20

echo
echo "--- ports bound by gateway pid 87559 (detail) ---"
lsof -nP -p 87559 -a -iTCP -sTCP:LISTEN 2>/dev/null | head

echo
echo "--- is there a dashboard on a high port? scan common 8080/3000/5173/8642/9900/9901 ---"
for P in 3000 5173 8080 8642 9000 9900 9901 9902; do
  if lsof -nP -iTCP:$P -sTCP:LISTEN >/dev/null 2>&1; then
    echo "  port $P: LISTENING (pid $(lsof -nP -iTCP:$P -sTCP:LISTEN -t 2>/dev/null | head -1))"
  fi
done
echo "=== Done ==="
