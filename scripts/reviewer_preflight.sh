#!/usr/bin/env bash
# Safe, local-only preflight for the external reviewer package.
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METADATA="$ROOT_DIR/docs/release/BETA-METADATA.md"
PROJECT="$ROOT_DIR/project.yml"
INFO="$ROOT_DIR/HermesFleetApp/Info.plist"
failures=0
warnings=0

fail() {
  printf 'FAIL: %s\n' "$1"
  failures=$((failures + 1))
}
warn() {
  printf 'HOLD: %s\n' "$1"
  warnings=$((warnings + 1))
}
ok() { printf 'OK: %s\n' "$1"; }

printf 'Hermes Fleet reviewer preflight (local, no ASC calls)\n'
printf 'Repository: %s\n\n' "$ROOT_DIR"

if [[ -f "$METADATA" ]]; then
  # Placeholders are deliberately safe in git, but must be resolved privately
  # in App Store Connect before submission.
  if grep -Fq '[TONY:' "$METADATA"; then
    fail 'BETA-METADATA.md still contains Tony App Store Connect placeholders'
  else
    ok 'beta metadata has no unresolved Tony placeholders'
  fi
  for required in '## Beta App Description' '## Feedback Email' '## What to Test' '## Beta App Review contact' '## Review notes' '## Demo access fields'; do
    if grep -Fq "$required" "$METADATA"; then
      ok "metadata section present: $required"
    else
      fail "metadata section missing: $required"
    fi
  done
  if grep -Eiq '(password|token|secret|BEGIN [A-Z ]+ KEY|qr.*payload)[=:][[:space:]]*[^<[]' "$METADATA"; then
    fail 'metadata may contain inline access material; inspect without printing secrets'
  else
    ok 'metadata contains no obvious inline access material'
  fi
else
  fail 'missing docs/release/BETA-METADATA.md'
fi

# URL is supplied at invocation time so no maintainer or policy endpoint is
# embedded in the repository. Placeholder values are intentionally rejected.
policy_url="${PRIVACY_POLICY_URL:-}"
if [[ -z "$policy_url" || "$policy_url" == *'<'* || "$policy_url" == *'>'* || "$policy_url" == *'['* || "$policy_url" == *'TONY'* ]]; then
  fail 'PRIVACY_POLICY_URL is unset or still a placeholder (set it only for a real pre-submission check)'
elif [[ "$policy_url" != https://* ]]; then
  fail 'PRIVACY_POLICY_URL must use HTTPS'
elif curl -fsSIL --max-time 10 -- "$policy_url" >/dev/null 2>&1; then
  ok 'privacy-policy URL is reachable over HTTPS'
else
  fail 'privacy-policy URL did not respond successfully over HTTPS'
fi

# Read the declaration from both source-of-truth candidates without dumping
# the generated bundle or any unrelated Info.plist values.
info_value=''
if [[ -f "$INFO" ]]; then
  if grep -Eq '<key>ITSAppUsesNonExemptEncryption</key>[[:space:]]*$' "$INFO" && \
     grep -A1 -E '<key>ITSAppUsesNonExemptEncryption</key>[[:space:]]*$' "$INFO" | grep -q '<false/>'; then
    info_value=false
  elif grep -A1 -E '<key>ITSAppUsesNonExemptEncryption</key>[[:space:]]*$' "$INFO" | grep -q '<true/>'; then
    info_value=true
  fi
fi
project_value=''
if [[ -f "$PROJECT" ]]; then
  project_value="$(grep -E 'ITSAppUsesNonExemptEncryption[[:space:]]*:' "$PROJECT" | head -n1 | sed -E 's/.*:[[:space:]]*//')"
fi
if [[ -n "$info_value" && -n "$project_value" && "$info_value" != "$project_value" ]]; then
  fail "export-compliance declarations disagree between Info.plist and project.yml"
elif [[ "$info_value" == false || "$project_value" == false ]]; then
  warn 'ITSAppUsesNonExemptEncryption is declared false; Tony must confirm this remains truthful for the RC'
elif [[ "$info_value" == true || "$project_value" == true ]]; then
  warn 'ITSAppUsesNonExemptEncryption is declared true; Tony must complete the applicable export-compliance review'
else
  fail 'could not find ITSAppUsesNonExemptEncryption in project.yml or Info.plist'
fi

printf '\nResult: %s failure(s), %s human hold(s).\n' "$failures" "$warnings"
if (( failures > 0 )); then
  printf 'NOT READY: resolve failures before external submission.\n'
  exit 1
fi
printf 'LOCAL CHECKS COMPLETE: human holds remain before external submission.\n'
exit 0
