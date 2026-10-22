#!/bin/bash
# Regressions for per-path placeholder filtering in the public-safety guard.
set -u
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/hf_home_guard_test.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
mkdir -p "$REPO/scripts" "$REPO/docs"
git -C "$REPO" init -q
git -C "$REPO" config user.name "Home Guard Test"
git -C "$REPO" config user.email "home-guard-test@example.invalid"
cp "$ROOT_DIR/scripts/public_safety_guard.sh" "$REPO/scripts/"
git -C "$REPO" add scripts/public_safety_guard.sh

# Build synthetic paths in pieces so this test source does not carry a full
# disallowed home path literal.
HOME_PREFIX="/$(printf 'Us')ers/"
ALLOWED_USER="$(printf 'ex')ample"
DISALLOWED_USER="$(printf 'main')tainer"
PRIVATE_AREA="$(printf 'pri')vate"

run_case() { # name expected_exit fixture_line
  local name="$1" expected="$2" line="$3" rc
  printf '%s\n' "$line" > "$REPO/docs/fixture.txt"
  git -C "$REPO" add docs/fixture.txt
  if (cd "$REPO" && HF_PUBLIC_SAFETY_DENYLIST_FILE="$T/no-denylist" HF_PUBLIC_SAFETY_REQUIRE_PRIVATE=0 bash scripts/public_safety_guard.sh) >"$T/output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq "$expected" ]; then
    printf 'PASS  %s\n' "$name"
    return 0
  fi
  printf 'FAIL  %s (rc=%s, expected %s)\n' "$name" "$rc" "$expected" >&2
  return 1
}

FAILS=0
run_case "placeholder-only path passes" 0 "${HOME_PREFIX}${ALLOWED_USER}/docs" || FAILS=$((FAILS+1))
run_case "disallowed-only path fails" 1 "${HOME_PREFIX}${DISALLOWED_USER}/${PRIVATE_AREA}/docs" || FAILS=$((FAILS+1))
run_case "placeholder before disallowed path still fails" 1 "${HOME_PREFIX}${ALLOWED_USER}/docs ${HOME_PREFIX}${DISALLOWED_USER}/${PRIVATE_AREA}/docs" || FAILS=$((FAILS+1))
run_case "disallowed path before placeholder still fails" 1 "${HOME_PREFIX}${DISALLOWED_USER}/${PRIVATE_AREA}/docs ${HOME_PREFIX}${ALLOWED_USER}/docs" || FAILS=$((FAILS+1))

printf 'home path guard: %s failure(s)\n' "$FAILS"
[ "$FAILS" -eq 0 ]
