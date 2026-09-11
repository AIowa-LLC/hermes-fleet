#!/bin/bash
# reviewer_env_check.sh — pre-submission reachability check for the external
# reviewer Hermes gateway (issue #18). Verifies, using ONLY the endpoint and
# credentials Apple will receive, and following the EXACT wire sequence the
# Hermes Fleet app performs (FleetNetworking PasswordLogin + GatewayAuthenticator):
#
#   1. GET  /api/health            public liveness probe (always unauthenticated)
#   2. GET  /api/auth/providers    advertises the password-capable provider
#   3. POST /auth/password-login   {provider, username, password} -> session cookie
#   4. POST /api/auth/ws-ticket    cookie -> single-use WS ticket
#   5. POST /api/auth/ws-ticket    WITHOUT credentials must NOT return 200 —
#                                  proves the auth gate is genuinely engaged
#
# Secrets never appear in argv, stdout, or exit output. Run from an
# OFF-network vantage (phone hotspot / remote host) before every submission.
#
# Usage:
#   REVIEWER_BASE_URL=https://<host> [REVIEWER_CRED_FILE=<0600 file>] \
#     bash scripts/reviewer_env_check.sh
# Or via env: REVIEWER_USERNAME + REVIEWER_PASSWORD. With no arguments,
# smoke-targets the local launcher rehearsal instance (loopback). A loopback
# target is a TRANSPORT SMOKE ONLY: the dashboard auth gate is off by design
# (hermes exempts loopback hosts), and /api/auth/providers is not in the
# loopback public path set, so auth checks 2-5 are skipped rather than run
# into guaranteed 401s. A loopback smoke is never a pre-submission result.
#
# The full rehearsal (all 5 checks, gate genuinely engaged) is:
#   REVIEWER_PUBLIC_URL=http://<non-loopback-host>:9318 \
#     bash scripts/reviewer_env_launch.sh start
#   REVIEWER_BASE_URL=http://<non-loopback-host>:9318 \
#   REVIEWER_ALLOW_INSECURE_HTTP=1 \
#   REVIEWER_CONNECT_TO='<non-loopback-host>:9318:127.0.0.1:9318' \
#   REVIEWER_CRED_FILE="$REVIEWER_ENV_DIR/credentials" \
#     bash scripts/reviewer_env_check.sh
# (--connect-to must map the URL's port, not just the host — map
#  <host>:9318 to 127.0.0.1:9318, else curl falls back to real DNS.)
set -u

FAILURES=0
ok()   { printf 'OK:   %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
skip() { printf 'skip: %s\n' "$1"; }

BASE_URL="${REVIEWER_BASE_URL:-}"
CRED_FILE="${REVIEWER_CRED_FILE:-}"
LOOPBACK_SMOKE=0

is_loopback_url() {
  case "$1" in
    http://127.0.0.1*|http://localhost*|http://\[::1\]*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -z "$BASE_URL" ]; then
  BASE_URL="http://127.0.0.1:${REVIEWER_SERVE_PORT:-9318}"
  printf 'note: no REVIEWER_BASE_URL — smoke-targeting local rehearsal instance %s\n' "$BASE_URL"
fi
if is_loopback_url "$BASE_URL"; then
  LOOPBACK_SMOKE=1
fi
if [ "$LOOPBACK_SMOKE" = "1" ]; then
  printf 'note: loopback target — auth gate OFF by design (hermes exempts loopback hosts);\n'
  printf 'note: auth checks 2-5 are skipped (a healthy ungated loopback serve 401s them);\n'
  printf 'note: this is a transport smoke, NOT a pre-submission result.\n\n'
fi

# --- resolve credentials (env first, then 0600 file; NEVER argv) -------------
USERNAME="${REVIEWER_USERNAME:-}"
PASSWORD="${REVIEWER_PASSWORD:-}"
if { [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; } && [ -n "$CRED_FILE" ]; then
  if [ ! -f "$CRED_FILE" ]; then
    fail "credential file '$CRED_FILE' not found"
  elif [ "$(stat -c '%a' "$CRED_FILE" 2>/dev/null || stat -f '%Lp' "$CRED_FILE" 2>/dev/null || echo 000)" != "600" ]; then
    fail "credential file must be chmod 600"
  else
    USERNAME="$(sed -n 's/^username=//p' "$CRED_FILE")"
    PASSWORD="$(sed -n 's/^password=//p' "$CRED_FILE")"
  fi
fi
if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
  if [ "$LOOPBACK_SMOKE" = "1" ]; then
    printf 'note: no credentials given — fine for a loopback transport smoke (auth checks skipped).\n\n'
  else
    fail "no credentials: set REVIEWER_USERNAME/REVIEWER_PASSWORD or a 0600 REVIEWER_CRED_FILE"
    printf '\nResult: %s failure(s).\n' "$FAILURES"
    exit 1
  fi
fi

# --- transport policy ---------------------------------------------------------
# Rehearsal escape hatch ONLY: the local serve is plain HTTP, so an HTTPS
# rehearsal against it needs REVIEWER_ALLOW_INSECURE_HTTP=1 plus a
# plain-http base URL. Never set for a real pre-submission check.
ALLOW_INSECURE="${REVIEWER_ALLOW_INSECURE_HTTP:-0}"
case "$BASE_URL" in
  https://*) ok "base URL uses HTTPS ($BASE_URL)" ;;
  http://127.0.0.1*|http://localhost*) ok "loopback HTTP smoke target allowed ($BASE_URL)" ;;
  http://*) if [ "$ALLOW_INSECURE" = "1" ]; then
              ok "plain-HTTP non-loopback allowed (REHEARSAL ONLY — REVIEWER_ALLOW_INSECURE_HTTP=1)"
            else
              fail "REFUSING plain-HTTP non-loopback base URL ($BASE_URL) — Apple-facing endpoints must be HTTPS"
              printf '\nResult: %s failure(s).\n' "$FAILURES"; exit 1
            fi ;;
  *) fail "unrecognized base URL scheme ($BASE_URL)"
     printf '\nResult: %s failure(s).\n' "$FAILURES"; exit 1 ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/reviewer_check.XXXXXX")"
COOKIE_JAR="$WORK/cookies"
trap 'rm -rf "$WORK"' EXIT
umask 077

CURL_CONNECT=()
if [ -n "${REVIEWER_CONNECT_TO:-}" ]; then
  # Local rehearsal against an auth-gated serve: route the public hostname to
  # the loopback serve WITHOUT touching DNS, e.g.
  #   REVIEWER_CONNECT_TO='fleet-reviewer.example.com:9318:127.0.0.1:9318'
  # (the SOURCE port must match the base URL's port — port 80 only matches a
  # port-less http:// URL; --connect-to may remap the port too, unlike
  # --resolve; the Host header stays the trusted public host). Never needed
  # against the real tunnel.
  CURL_CONNECT=(--connect-to "$REVIEWER_CONNECT_TO")
fi

curl_cmd() { curl -sS --max-time 15 "${CURL_CONNECT[@]+"${CURL_CONNECT[@]}"}" "$@"; }

# --- 1. public health probe ---------------------------------------------------
HTTP="$(curl_cmd -o "$WORK/health.out" -w '%{http_code}' "$BASE_URL/api/health" 2>"$WORK/health.err" || true)"
if [ "$HTTP" = "200" ] && grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$WORK/health.out" 2>/dev/null; then
  ok "/api/health public liveness answered (HTTP 200)"
elif [ "$HTTP" = "200" ]; then
  ok "/api/health answered HTTP 200 (body shape not verified)"
else
  fail "/api/health unreachable or unhealthy (HTTP $HTTP)$( [ "$HTTP" = "000" ] && printf ' — %s' "$(head -c 200 "$WORK/health.err")" )"
fi

# --- 2. provider discovery (Fleet's first authenticated-surface call) ---------
PROVIDER=""
if [ "$LOOPBACK_SMOKE" = "1" ]; then
  skip "provider discovery (2): loopback smoke — not in the loopback public path set; verify via the full rehearsal"
else
HTTP="$(curl_cmd -o "$WORK/providers.out" -w '%{http_code}' "$BASE_URL/api/auth/providers" 2>"$WORK/providers.err" || true)"
if [ "$HTTP" = "200" ]; then
  # Same discovery rule as Fleet PasswordLogin: first provider advertising
  # password login. The bundled basic provider is named "basic".
  PROVIDER="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([a-zA-Z0-9_-]*\)"[^}]*"supports_password"[[:space:]]*:[[:space:]]*true.*/\1/p' "$WORK/providers.out" | head -1)"
  if [ -z "$PROVIDER" ]; then
    PROVIDER="$(sed -n 's/.*"supports_password"[[:space:]]*:[[:space:]]*true[^}]*"name"[[:space:]]*:[[:space:]]*"\([a-zA-Z0-9_-]*\)".*/\1/p' "$WORK/providers.out" | head -1)"
  fi
  if [ -n "$PROVIDER" ]; then
    ok "password-capable provider advertised: '$PROVIDER'"
  else
    fail "/api/auth/providers returned 200 but no password-capable provider found — the app cannot log in"
  fi
else
  fail "/api/auth/providers unreachable (HTTP $HTTP)"
fi
fi

# --- 3. password login (exact Fleet wire shape) -------------------------------
LOGIN_HTTP="skip"
if [ "$LOOPBACK_SMOKE" = "1" ]; then
  skip "password login (3): loopback smoke — auth surface not exercised; verify via the full rehearsal"
elif [ -n "$PROVIDER" ]; then
  LOGIN_HTTP="$(curl_cmd -o "$WORK/login.out" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    --data-binary "$(printf '{"provider":"%s","username":"%s","password":"%s"}' "$PROVIDER" "$USERNAME" "$PASSWORD")" \
    -c "$COOKIE_JAR" \
    "$BASE_URL/auth/password-login" 2>"$WORK/login.err" || true)"
  if [ "$LOGIN_HTTP" = "200" ] && [ -s "$COOKIE_JAR" ]; then
    ok "password login accepted; session cookie set"
  elif [ "$LOGIN_HTTP" = "429" ]; then
    fail "password login rate-limited (HTTP 429) — wait and retry; do not hammer the reviewer gateway"
  else
    body_hint="$(head -c 120 "$WORK/login.out" 2>/dev/null | tr -d '\n')"
    fail "password login failed (HTTP $LOGIN_HTTP)${body_hint:+ — $body_hint}"
  fi
else
  fail "skipping login — no provider discovered"
fi

# --- 4. ws-ticket WITH credentials (the Fleet WS upgrade path) ----------------
if [ "$LOOPBACK_SMOKE" = "1" ]; then
  skip "ws-ticket with credentials (4): loopback smoke — auth surface not exercised; verify via the full rehearsal"
elif [ "$LOGIN_HTTP" = "200" ]; then
  HTTP="$(curl_cmd -o "$WORK/ticket.out" -w '%{http_code}' \
    -X POST -b "$COOKIE_JAR" \
    "$BASE_URL/api/auth/ws-ticket" 2>"$WORK/ticket.err" || true)"
  if [ "$HTTP" = "200" ]; then
    ok "ws-ticket minted with session cookie (HTTP 200)"
  else
    fail "ws-ticket failed with credentials (HTTP $HTTP)"
  fi
fi

# --- 5. NEGATIVE probe: ws-ticket WITHOUT credentials must NOT be 200 ---------
if [ "$LOOPBACK_SMOKE" = "0" ]; then
  HTTP="$(curl_cmd -o "$WORK/neg.out" -w '%{http_code}' \
    -X POST "$BASE_URL/api/auth/ws-ticket" 2>"$WORK/neg.err" || true)"
  if [ "$HTTP" = "000" ]; then
    fail "negative probe unreachable — cannot confirm the auth gate from here"
  elif [ "$HTTP" = "200" ]; then
    fail "AUTH GATE NOT ENGAGED: /api/auth/ws-ticket returned 200 WITHOUT credentials — the endpoint is publicly open; do not submit"
  else
    ok "auth gate engaged: unauthenticated ws-ticket denied (HTTP $HTTP)"
  fi
else
  skip "negative auth probe (5) skipped for loopback smoke (gate off by design)"
fi

printf '\nResult: %s failure(s).\n' "$FAILURES"
if [ "$FAILURES" -gt 0 ]; then
  printf 'NOT READY: resolve failures before external submission.\n'
  exit 1
fi
if [ "$LOOPBACK_SMOKE" = "1" ]; then
  printf 'LOOPBACK TRANSPORT SMOKE PASSED — this is NOT a pre-submission result; run the full check against the real HTTPS endpoint.\n'
  exit 0
fi
printf 'REVIEWER ENDPOINT READY (from this vantage point).\n'
