#!/bin/bash
# L1 live gateway dogfood — PHASE 1 probe #8: auth mode of each serve surface,
# session-token env PRESENCE (never the value), and serve/dashboard host opts.
# No secrets printed.
set -u

echo "=== L1 probe 8: auth modes + LAN-surface options ==="

echo
echo "--- /api/auth/status body per serve surface (non-secret flags) ---"
for BASE in "http://127.0.0.1:63597" "http://127.0.0.1:52875" "http://127.0.0.1:63474"; do
  echo "  $BASE:"
  curl -s -m 3 "$BASE/api/auth/status" 2>/dev/null | head -c 300; echo
done

echo
echo "--- HERMES_DASHBOARD_SESSION_TOKEN presence in key processes (boolean only) ---"
for PID in 87559 87716 8108 7263 1235; do
  if ps -p $PID >/dev/null 2>&1; then
    if tr '\0' '\n' < /proc/$PID/environ 2>/dev/null | grep -q "^HERMES_DASHBOARD_SESSION_TOKEN="; then
      echo "  PID $PID: HERMES_DASHBOARD_SESSION_TOKEN = SET (value withheld)"
    else
      echo "  PID $PID: HERMES_DASHBOARD_SESSION_TOKEN = not set in /proc (macOS, checking ps env via launchctl not possible; env likely random per-process)"
    fi
  fi
done

echo
echo "--- serve / dashboard host options ---"
~/.hermes/hermes-agent/venv/bin/hermes serve --help 2>&1 | grep -iE "host|port|insecure|bind|0.0.0.0" | head -15
echo "--- dashboard --help ---"
~/.hermes/hermes-agent/venv/bin/hermes dashboard --help 2>&1 | grep -iE "host|port|insecure|bind|0.0.0.0" | head -15

echo
echo "=== Done ==="
