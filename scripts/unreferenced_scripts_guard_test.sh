#!/bin/bash
# Self-test for unreferenced_scripts_guard.sh. Builds throwaway git repositories
# and asserts the guard passes/fails as specified. Hermetic: no network, no
# access to the real repository tree beyond copying the guard script.
set -u
GUARD="$(cd "$(dirname "$0")" && pwd)/unreferenced_scripts_guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
check() { # name expected_exit actual_exit
  if [ "$2" = "$3" ]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s (expected exit %s, got %s)\n' "$1" "$2" "$3"
    FAILS=$((FAILS+1))
  fi
}

new_repo() {
  R="$TMP/$1"
  mkdir -p "$R/scripts/archive" "$R/docs/archive" "$R/.github/workflows"
  ( cd "$R" && git init -q . )
  cp "$GUARD" "$R/scripts/unreferenced_scripts_guard.sh"
  : > "$R/scripts/unreferenced_allowlist.txt"
  printf '#!/bin/bash\n' > "$R/scripts/live_tool.sh"
  printf 'steps:\n  - run: bash scripts/live_tool.sh\n  - run: bash scripts/unreferenced_scripts_guard.sh\n' > "$R/.github/workflows/ci.yml"
}
run_guard() {
  ( cd "$R" && git add -A >/dev/null 2>&1 && bash scripts/unreferenced_scripts_guard.sh >"$TMP/out.txt" 2>&1 )
}

# 1. Baseline: only referenced scripts -> pass.
new_repo base; run_guard; check "baseline tree passes" 0 $?

# 2. Synthetic unreferenced script -> fail and is named.
new_repo orphan; printf '#!/bin/bash\n' > "$R/scripts/milestone_one_off.sh"
run_guard; rc=$?; check "unreferenced script fails" 1 $rc
grep -q 'scripts/milestone_one_off.sh' "$TMP/out.txt"; check "failure names the script" 0 $?

# 3. Reference only from scripts/archive or docs/archive does not count.
new_repo archref; printf '#!/bin/bash\n' > "$R/scripts/only_archived_ref.sh"
printf 'bash scripts/only_archived_ref.sh\n' > "$R/scripts/archive/old.sh"
printf 'run scripts/only_archived_ref.sh\n' > "$R/docs/archive/old.md"
run_guard; check "archive-only references do not count" 1 $?

# 4. Reference from a doc counts.
new_repo docref; printf '#!/bin/bash\n' > "$R/scripts/documented.sh"
printf 'Run `scripts/documented.sh` first.\n' > "$R/docs/guide.md"
run_guard; check "doc reference counts" 0 $?

# 5. A longer basename does not cover a shorter one (substring is not a reference).
new_repo substr; printf '#!/bin/bash\n' > "$R/scripts/name.sh"
printf 'bash scripts/longer_name.sh\n' > "$R/docs/guide.md"
run_guard; check "substring of another name does not count" 1 $?

# 6. Allowlisted script passes; the allowlist file is not itself a reference.
new_repo allow; printf '#!/bin/bash\n' > "$R/scripts/manual_probe.sh"
run_guard; check "unlisted manual tool fails" 1 $?
printf 'manual_probe.sh  # maintained manual tool\n' > "$R/scripts/unreferenced_allowlist.txt"
run_guard; check "allowlisted manual tool passes" 0 $?

if [ "$FAILS" -ne 0 ]; then
  echo "unreferenced_scripts_guard self-test: $FAILS failure(s)"
  exit 1
fi
echo "unreferenced_scripts_guard self-test: all checks passed"
