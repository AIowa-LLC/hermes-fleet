#!/bin/bash
# F2 (t_b678fb38) E2E auth verification against the live HTTPS tunnel.
#
# Verifies the app's auth surface over TLS, as far as possible WITHOUT the
# gateway password:
#   1. GET  /api/auth/providers  (pre-auth discovery)          -> 200
#   2. POST /auth/password-login (wrong credential)            -> 401
#   3. POST /api/auth/ws-ticket  (no credential)               -> 401
#   4. Audit-trail check: a successful basic login over TLS is
#      evidenced in the gateway audit log (orchestrator's 05:35
#      verification with the real credential).
#
# The positive login-with-credential leg is verified on the SHIPPED
# ARTIFACT by apple-qa (F2 QA gate 2) using Tony's credential.
set -uo pipefail

HOST="${HERMES_FLEET_LIVE_ENDPOINT:?Set HERMES_FLEET_LIVE_ENDPOINT to YOUR HTTPS gateway origin — this probe targets no infrastructure by default}"
SSH_KEY="${HERMES_FLEET_AUDIT_SSH_KEY:-}"
AUDIT_HOST="${HERMES_FLEET_AUDIT_SSH_HOST:-}"
AUDIT_LOG="${HERMES_FLEET_AUDIT_LOG_PATH:-}"

fail() { echo "FAIL: $1"; exit "${2:-1}"; }

# 1. providers
P_CODE=$(curl -s -o /tmp/f2_p.json -w '%{http_code}' --max-time 15 "$HOST/api/auth/providers")
echo "providers: $P_CODE"
[[ "$P_CODE" == "200" ]] || fail "providers surface" 3
grep -q '"basic"' /tmp/f2_p.json || fail "basic provider missing" 4
rm -f /tmp/f2_p.json

# 2. Login endpoint enforces credentials (F1 classified-401 contract). A
#    deliberately-wrong credential must get 401, NOT 404/500 — proving the
#    login surface is live over TLS and credential-gated.
L_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "$HOST/auth/password-login" -H 'Content-Type: application/json' -d '{"provider":"basic","username":"hermes-fleet","password":"definitely-not-the-fleet-password"}')
echo "password-login (wrong credential): $L_CODE (expect 401)"
[[ "$L_CODE" == "401" ]] || fail "login surface not enforcing credentials (got $L_CODE)" 5

# 3. Unauthenticated ws-ticket mint must be rejected (F1 401-classification).
T0=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "$HOST/api/auth/ws-ticket" -H 'Accept: application/json')
echo "ws-ticket (no credential): $T0 (expect 401)"
[[ "$T0" == "401" ]] || fail "ticket mint not credential-gated" 7

# 4. Audit evidence (optional — only when SSH audit config is provided).
#    Boolean only — no tokens, no credentials, no IPs printed.
#    Result honesty: the final verdict only claims audit verification when
#    the audit leg actually ran AND found evidence. A skipped audit yields
#    a SURFACE-ONLY verdict that says the audit was SKIPPED.
AUDIT_RAN=0
if [ -n "$AUDIT_HOST" ] && [ -n "$SSH_KEY" ] && [ -n "$AUDIT_LOG" ]; then
  AUDIT=$(ssh -o BatchMode=yes -i "$SSH_KEY" "$AUDIT_HOST" "grep -c '\"event\":\"login_success\",\"provider\":\"basic\"' \"$AUDIT_LOG\" 2>/dev/null || echo 0")
  echo "audit: login_success over TLS evidenced: $AUDIT time(s)"
  [[ "$AUDIT" -gt 0 ]] || fail "no successful TLS login in the gateway audit log" 9
  AUDIT_RAN=1
else
  echo "audit: SKIPPED (no HERMES_FLEET_AUDIT_SSH_KEY/_HOST/_LOG_PATH configured)"
fi

if [ "$AUDIT_RAN" -eq 1 ]; then
  echo "E2E AUTH VERIFIED (FULL): providers 200, login gated 401, ticket mint gated 401, TLS login_success in audit"
else
  echo "E2E AUTH SURFACE VERIFIED (SURFACE-ONLY): providers 200, login gated 401, ticket mint gated 401 — audit NOT checked (skipped)"
fi
echo "NOTE: full login+ws-ticket with the real credential = QA gate 2 on the shipped artifact."
