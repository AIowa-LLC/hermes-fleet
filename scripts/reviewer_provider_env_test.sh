#!/bin/bash
# reviewer_provider_env_test.sh — executable regression tests for the
# reviewer provider-env allowlist (issue #18 v2, BLOCKER 1).
#
# Proves, by execution, that a reused/malicious .env file CANNOT override:
#   HOME, PATH, any HERMES_* setting (auth, public URL, home), reviewer/auth/
#   tunnel control variables, shell/runtime manipulation variables, host
#   control/credential material (SSH agent, docker socket, kubeconfig, cloud
#   and VCS tokens), or sneak in unknown keys — and that legitimate
#   model-provider keys DO pass.
#
# Exit 0 = all tests pass. Any failure prints the offending case.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=reviewer_provider_env_lib.sh
. "$SCRIPT_DIR/reviewer_provider_env_lib.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }

expect_reject() {  # key must be rejected (any reason)
  if reviewer_provider_key_check "$1" >/dev/null 2>&1; then
    bad "allowlisted a forbidden key: $1"
  else
    ok "rejected forbidden key: $1"
  fi
}
expect_accept() {
  if reviewer_provider_key_check "$1" >/dev/null 2>&1; then
    ok "allowed provider key: $1"
  else
    bad "rejected a legitimate provider key: $1"
  fi
}

echo "== BLOCKER 1 regression: protected environment must not be overridable =="

# --- the exact variables named in the security review ----------------------
expect_reject HOME
expect_reject PATH
expect_reject HERMES_HOME
expect_reject HERMES_DASHBOARD_PUBLIC_URL
expect_reject HERMES_DASHBOARD_BASIC_AUTH_USERNAME
expect_reject HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
expect_reject HERMES_DASHBOARD_BASIC_AUTH_SECRET
expect_reject HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH
expect_reject HERMES_TIMEZONE

# --- broader HERMES_* surface (whole namespace) ------------------------------
for k in HERMES_PROVIDER HERMES_ANYTHING_NEW HERMES_SERVE_PORT HERMES_ENABLE_PROJECT_PLUGINS; do
  expect_reject "$k"
done

# --- shell/runtime manipulation ---------------------------------------------
for k in ENV BASH_ENV SHELLOPTS IFS LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES PYTHONPATH PYTHONSTARTUP NODE_OPTIONS VIRTUAL_ENV TMPDIR; do
  expect_reject "$k"
done

# --- reviewer/auth/tunnel control -------------------------------------------
for k in REVIEWER_USERNAME REVIEWER_PASSWORD REVIEWER_SECRET REVIEWER_PUBLIC_URL REVIEWER_PROVIDER_ENV_FILE REVIEWER_SERVE_PORT REVIEWER_BASE_URL CLOUDFLARED_TOKEN TUNNEL_TOKEN CF_API_TOKEN; do
  expect_reject "$k"
done

# --- host control / credential material -------------------------------------
# Includes the provider-registry / provider-category keys this environment
# deliberately excludes (see the lib header) plus non-provider credential
# classes (SSH agent, docker socket, kubeconfig, cloud keys, dotenv include).
for k in GITHUB_TOKEN GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN AWS_SECRET_ACCESS_KEY AWS_ACCESS_KEY_ID AWS_PROFILE AWS_REGION VERTEX_CREDENTIALS_PATH HERMES_QWEN_BASE_URL SSH_AUTH_SOCK DOCKER_HOST KUBECONFIG HEROKU_API_KEY DOTENV_PATH; do
  expect_reject "$k"
done

# --- legitimate provider keys pass (sample across the merged canonical set) --
for k in \
  OPENAI_API_KEY OPENAI_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_TOKEN ANTHROPIC_BASE_URL \
  GOOGLE_API_KEY GEMINI_API_KEY GEMINI_BASE_URL GLM_API_KEY ZAI_API_KEY Z_AI_API_KEY \
  OPENROUTER_API_KEY META_API_KEY META_MODEL_API_KEY MODEL_API_KEY ROUTER_API_KEY \
  COMMANDCODE_API_KEY XAI_API_KEY XAI_BASE_URL UPSTAGE_API_KEY \
  DEEPSEEK_API_KEY DEEPSEEK_BASE_URL MINIMAX_API_KEY MINIMAX_CN_API_KEY MINIMAX_CN_BASE_URL \
  NOVITA_API_KEY NEBIUS_API_KEY DEEPINFRA_API_KEY DASHSCOPE_API_KEY FIREWORKS_API_KEY \
  KIMI_API_KEY KIMI_CN_API_KEY NVIDIA_API_KEY OLLAMA_API_KEY HF_TOKEN TOKENPLAN_API_KEY ; do
  expect_accept "$k"
done

# --- exact matching: near-miss names must NOT be admitted --------------------
# The allowlist is newline-delimited; a substring match would admit a prefix
# or an infix of a real key name. These must all be rejected.
for k in OPENAI_API_KE PENAI_API_KEY OPENAI_API_KEY_ OPENAI_API_KEYX; do
  expect_reject "near-miss ($k)"
done

# --- malformed / unknown ------------------------------------------------------
# GROQ_API_KEY / MISTRAL_API_KEY / TOGETHER_API_KEY / PERPLEXITY_API_KEY are
# NOT Hermes 0.21.1 provider variables (absent from both PROVIDER_REGISTRY and
# OPTIONAL_ENV_VARS category "provider") — deliberately unknown here.
for k in GROQ_API_KEY MISTRAL_API_KEY TOGETHER_API_KEY PERPLEXITY_API_KEY OPENAI_API_KEY_BACKDOOR HERMES__ X BAD-KEY ""; do
  expect_reject "$k"
done

echo
echo "== file-level validation: mixed file rejected, clean file accepted =="
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

printf 'OPENAI_API_KEY=sk-test-123\n# comment\n\nGEMINI_API_KEY=abc\n' > "$T/clean.env"
chmod 600 "$T/clean.env"
if out="$(reviewer_provider_env_validate "$T/clean.env")" \
   && [ "$(printf '%s\n' "$out" | sort | tr '\n' ' ')" = "GEMINI_API_KEY OPENAI_API_KEY " ]; then
  ok "clean provider file: both keys forwarded"
else
  bad "clean provider file should forward exactly the two provider keys (got: $out)"
fi

printf 'OPENAI_API_KEY=x\nHOME=/tmp/evil\nHERMES_DASHBOARD_BASIC_AUTH_PASSWORD=pwn\nPATH=/evil:%s\nUNKNOWN_KEY=1\n' "$PATH" > "$T/malicious.env"
chmod 600 "$T/malicious.env"
if reviewer_provider_env_validate "$T/malicious.env" >/dev/null 2>&1; then
  bad "malicious provider file was ACCEPTED — protected env overridable"
else
  ok "malicious provider file rejected (HOME/HERMES_*/PATH/unknown all refused)"
fi

printf 'OPENAI_API_KEY=x\n' > "$T/loose.env"; chmod 644 "$T/loose.env"
if reviewer_provider_env_validate "$T/loose.env" >/dev/null 2>&1; then
  bad "non-0600 provider file accepted"
else
  ok "non-0600 provider file rejected"
fi

printf 'OPENAI_API_KEY=has"quote\n' > "$T/quote.env"; chmod 600 "$T/quote.env"
if reviewer_provider_env_validate "$T/quote.env" >/dev/null 2>&1; then
  bad "quote-smuggling value accepted"
else
  ok "value with embedded quote rejected (docker CLI injection guard)"
fi

v_bs1='has\onebackslash'; printf 'OPENAI_API_KEY=%s\n' "$v_bs1" > "$T/bslash1.env"; chmod 600 "$T/bslash1.env"
if reviewer_provider_env_validate "$T/bslash1.env" >/dev/null 2>&1; then
  bad "SINGLE-backslash value accepted (quoted case pattern matches only doubled backslashes)"
else
  ok "value with a single embedded backslash rejected (docker CLI injection guard)"
fi

v_bs2='has\\twobackslashes'; printf 'OPENAI_API_KEY=%s\n' "$v_bs2" > "$T/bslash2.env"; chmod 600 "$T/bslash2.env"
if reviewer_provider_env_validate "$T/bslash2.env" >/dev/null 2>&1; then
  bad "doubled-backslash value accepted"
else
  ok "value with doubled backslashes rejected"
fi

printf 'OPENAI_API_KEY=aaaa\nOPENAI_API_KEY=bbbb\n' > "$T/dup.env"; chmod 600 "$T/dup.env"
if reviewer_provider_env_validate "$T/dup.env" >/dev/null 2>&1; then
  bad "duplicate-key file accepted (sed re-extraction would splice a newline control char into -e)"
else
  ok "duplicate key rejected (no newline control char can reach the container env)"
fi

printf 'OPENAI_API_KEY=has\ttab\n' > "$T/ctrl.env"; chmod 600 "$T/ctrl.env"
if reviewer_provider_env_validate "$T/ctrl.env" >/dev/null 2>&1; then
  bad "control-character value accepted"
else
  ok "value with control character rejected (docker CLI injection guard)"
fi

printf 'KEY_NO_EQUALS\n' > "$T/malformed.env"; chmod 600 "$T/malformed.env"
if reviewer_provider_env_validate "$T/malformed.env" >/dev/null 2>&1; then
  bad "malformed line accepted"
else
  ok "malformed (non KEY=value) line rejected"
fi

if reviewer_provider_env_validate "$T/missing.env" >/dev/null 2>&1; then
  bad "missing file accepted"
else
  ok "missing file: rejected (fail closed)"
fi

echo
printf 'provider-env allowlist tests: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
