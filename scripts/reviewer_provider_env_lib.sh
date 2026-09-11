#!/bin/bash
# reviewer_provider_env_lib.sh — the ONE definition of which provider-model
# credential variables the reviewer environment will forward into the demo
# container (issue #18 v2, BLOCKER 1). Sourced by reviewer_env_launch.sh
# (enforcement) and by reviewer_provider_env_test.sh (executable regression
# tests). Fail closed: any key not on this list aborts the launch.
#
# Security contract (issue #18 remediation, BLOCKER 1):
#   - ONLY model-provider credential variables may be forwarded.
#   - Any HERMES_* variable is rejected: the launcher owns the Hermes
#     security configuration (auth, public URL, home) and a reused .env must
#     never be able to override it.
#   - HOME, PATH, and every shell/runtime manipulation variable is rejected.
#   - Reviewer/auth/tunnel control variables are rejected.
#   - Host-control / host-credential material (SSH agent, docker socket,
#     kubeconfig, cloud keys, VCS tokens) is rejected.
#   - Unknown keys are rejected — the list is an allowlist, not a blocklist.
#   - Values containing quotes, backslashes, or control characters are
#     rejected: the file is replayed as docker `-e KEY=value` arguments and
#     such values would be misparsed by the shell or the docker CLI.
#
# Provenance: the UNION of (a) every provider config's api-key env vars and
# base-URL env var in `hermes_cli.auth.PROVIDER_REGISTRY` and (b) every
# `hermes_cli.config.OPTIONAL_ENV_VARS` entry with category "provider"
# (openrouter and other aggregators are declared only in (b)). At the pinned
# image version (hermes 0.21.1) that union is 100 variables; 7 documented
# exclusions leave the 93 entries below. Regenerate instead of hand-editing:
#   python3 -c "from hermes_cli.config import OPTIONAL_ENV_VARS as O; \
#     from hermes_cli.auth import PROVIDER_REGISTRY as R; \
#     print(sorted({n for n,m in O.items() if m.get('category')=='provider'} \
#       | {k for p in R.values() for k in (getattr(p,'api_key_env_vars',()) or ())} \
#       | {p.base_url_env_var for p in R.values() if p.base_url_env_var}))"
#
# Deliberately EXCLUDED from the allowlist (each is also rejected explicitly
# in reviewer_provider_key_is_forbidden, so editing the list cannot silently
# re-admit it even though Hermes's own tables declare it):
#   - GH_TOKEN / GITHUB_TOKEN — GitHub Copilot provider keys, but also the
#     operator's full VCS credential (they are on Hermes's own static child
#     env blocklist, tools/environments/local_env_policy.py).
#   - CLAUDE_CODE_OAUTH_TOKEN — belongs to the operator's Claude Code install,
#     not to Hermes (same policy file).
#   - AWS_PROFILE / AWS_REGION — cloud credential-chain selection, not a
#     forwardable demo chat key.
#   - VERTEX_CREDENTIALS_PATH — a host-side path to a GCP service-account
#     JSON, not a credential value.
#   - HERMES_QWEN_BASE_URL — the launcher owns the whole HERMES_* namespace,
#     so that class wins over a provider-category entry.
# TTS/STT, messaging, and search-tool credentials are excluded for the same
# reason: the demo needs chat inference only.

REVIEWER_PROVIDER_ALLOWED_KEYS="
ACTUAL_API_KEY
ACTUAL_BASE_URL
AI_GATEWAY_API_KEY
AI_GATEWAY_BASE_URL
ALIBABA_CODING_PLAN_API_KEY
ALIBABA_CODING_PLAN_BASE_URL
ALIBABA_CODING_PLAN_CN_API_KEY
ALIBABA_CODING_PLAN_CN_BASE_URL
ALIBABA_TOKEN_PLAN_API_KEY
ALIBABA_TOKEN_PLAN_BASE_URL
ALIBABA_TOKEN_PLAN_CN_API_KEY
ALIBABA_TOKEN_PLAN_CN_BASE_URL
ANTHROPIC_API_KEY
ANTHROPIC_BASE_URL
ANTHROPIC_TOKEN
ARCEEAI_API_KEY
ARCEE_BASE_URL
AZURE_FOUNDRY_API_KEY
AZURE_FOUNDRY_BASE_URL
BEDROCK_BASE_URL
COMMANDCODE_ANTHROPIC_BASE_URL
COMMANDCODE_API_KEY
COMMANDCODE_BASE_URL
COPILOT_ACP_BASE_URL
COPILOT_API_BASE_URL
COPILOT_GITHUB_TOKEN
DASHSCOPE_API_KEY
DASHSCOPE_BASE_URL
DASHSCOPE_CN_BASE_URL
DEEPINFRA_API_KEY
DEEPINFRA_BASE_URL
DEEPSEEK_API_KEY
DEEPSEEK_BASE_URL
FIREWORKS_API_KEY
GEMINI_API_KEY
GEMINI_BASE_URL
GLM_API_KEY
GLM_BASE_URL
GMI_API_KEY
GMI_BASE_URL
GOOGLE_API_KEY
HF_BASE_URL
HF_TOKEN
KILOCODE_API_KEY
KILOCODE_BASE_URL
KIMI_API_KEY
KIMI_BASE_URL
KIMI_CN_API_KEY
KIMI_CODING_API_KEY
LM_API_KEY
LM_BASE_URL
META_API_KEY
META_BASE_URL
META_MODEL_API_KEY
MINIMAX_API_KEY
MINIMAX_BASE_URL
MINIMAX_CN_API_KEY
MINIMAX_CN_BASE_URL
MODEL_API_KEY
NEBIUS_API_KEY
NEBIUS_BASE_URL
NEBIUS_TOKEN_FACTORY_API_KEY
NOUS_BASE_URL
NOVITA_API_KEY
NOVITA_BASE_URL
NVIDIA_API_KEY
NVIDIA_BASE_URL
OLLAMA_API_KEY
OLLAMA_BASE_URL
OPENAI_API_KEY
OPENAI_BASE_URL
OPENCODE_GO_API_KEY
OPENCODE_GO_BASE_URL
OPENCODE_ZEN_API_KEY
OPENCODE_ZEN_BASE_URL
OPENROUTER_API_KEY
RAMP_ROUTER_API_KEY
RAMP_ROUTER_BASE_URL
ROUTER_API_KEY
STEPFUN_API_KEY
STEPFUN_BASE_URL
TOKENHUB_API_KEY
TOKENHUB_BASE_URL
TOKENPLAN_API_KEY
TOKENPLAN_BASE_URL
UPSTAGE_API_KEY
UPSTAGE_BASE_URL
XAI_API_KEY
XAI_BASE_URL
XIAOMI_API_KEY
XIAOMI_BASE_URL
ZAI_API_KEY
Z_AI_API_KEY
"
# Categories that must NEVER be forwarded, checked BEFORE the allowlist so a
# typo'd allowlist entry can never silently admit them.
reviewer_provider_key_is_forbidden() {
  case "$1" in
    # launcher-owned Hermes security surface
    HERMES_*) return 0 ;;
    # identity / filesystem / runtime
    HOME|PWD|OLDPWD|USER|LOGNAME|SHELL|TERM|LANG|LC_*|TMPDIR) return 0 ;;
    PATH|LD_*|DYLD_*|PYTHON*|NODE_*|npm_*|VIRTUAL_ENV|CLASSPATH) return 0 ;;
    # process/shell manipulation
    ENV|PS1|PS2|BASH_ENV|SHELLOPTS|POSIXLY_CORRECT|IFS) return 0 ;;
    # reviewer/auth/tunnel control — owned by the launcher, not the env file
    REVIEWER_*) return 0 ;;
    CLOUDFLARED_*|TUNNEL_*|CF_*) return 0 ;;
    # credential-shaped launcher inputs
    SSH_AUTH_SOCK|SSH_*|DOCKER_HOST|DOCKER_*|KUBECONFIG|HEROKU_API_KEY|DOTENV*) return 0 ;;
    AWS_*|GH_TOKEN|GITHUB_TOKEN|CLAUDE_CODE_OAUTH_TOKEN) return 0 ;;
    *) return 1 ;;
  esac
}

reviewer_provider_key_is_allowed() {
  local key="$1" k
  for k in $REVIEWER_PROVIDER_ALLOWED_KEYS; do
    [ "$k" = "$key" ] && return 0
  done
  return 1
}

# Validate one KEY (name only). Returns 0 = allowed, 1 = forbidden, 2 = unknown.
reviewer_provider_key_check() {
  local key="$1"
  case "$key" in
    ''|*[!A-Za-z0-9_]*) return 2 ;;  # malformed names are unknown, not allowed
  esac
  if reviewer_provider_key_is_forbidden "$key"; then return 1; fi
  if reviewer_provider_key_is_allowed "$key"; then return 0; fi
  return 2
}

# Validate a provider env FILE. Prints one line per accepted key (KEY only,
# never the value) to stdout; rejects the whole file (exit 1, list of
# offenders on stderr) if ANY line is malformed or not allowlisted.
reviewer_provider_env_validate() {
  local file="$1" line key value bad=0 seen=""
  [ -f "$file" ] || { printf 'provider env file not found: %s\n' "$file" >&2; return 1; }
  local mode
  mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || echo 000)"
  [ "$mode" = "600" ] || { printf 'provider env file must be chmod 600 (is %s)\n' "$mode" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '#'*|'') continue ;; esac
    case "$line" in
      *=*) key="${line%%=*}"; value="${line#*=}" ;;
      *) printf 'malformed line (no KEY=value): %s\n' "${line:0:40}" >&2; bad=1; continue ;;
    esac
    # reject values that smuggle quotes/backslashes/control chars the shell
    # or docker CLI could misparse when the file is replayed as -e arguments.
    # NOTE: the backslash alternative must be UNQUOTED (`*\\*`) — a quoted
    # `'\\'` is a literal two-character pattern that matches only doubled
    # backslashes, silently admitting a single one.
    case "$value" in
      *'"'*|*"'"*|*\\*|*$'\n'*|*[[:cntrl:]]*)
        printf 'unsafe character in value for %s (quotes/backslash/control)\n' "$key" >&2; bad=1; continue ;;
    esac
    # reject duplicate keys: the launcher re-extracts values with sed over the
    # whole file, so a repeated key would splice multiple lines (newline
    # control character) into one -e argument.
    case " $seen " in
      *" $key "*)
        printf 'duplicate key %s in provider env file — refusing (fail closed)\n' "$key" >&2; bad=1; continue ;;
    esac
    seen="$seen $key"
    if reviewer_provider_key_check "$key"; then
      printf '%s\n' "$key"
    else
      printf 'REJECTED key not on provider allowlist: %s\n' "$key" >&2
      bad=1
    fi
  done < "$file"
  [ "$bad" -eq 0 ] || return 1
}
