#!/bin/bash
# t_eb5455f2: repopulate the auth-flow evidence (the earlier capture was in the
# sim log store; re-query the last hour of the subsystem log).
set -u
cd <repo-root> || exit 1
E=build/p3fix_evidence
xcrun simctl spawn booted log show --last 1h --info --debug \
  --predicate 'subsystem == "com.aiowa.hermesfleet"' 2>/dev/null \
  | grep -aE "password-login|ws-ticket" | tail -12 | tee "$E/auth_flow.log"
echo "=== Done ==="
