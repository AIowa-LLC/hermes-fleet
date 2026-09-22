#!/bin/bash
# repo_hygiene.sh — one-command repository hygiene audit for Hermes Fleet.
#
# Answers, with evidence: is the repo in the exact shape we expect?
#   1. Canonical repository identity (not the quarantined mirror)
#   2. Expected branch/worktree topology (main + one active lane)
#   3. Every worktree clean (no uncommitted tracked changes, no stashes)
#   4. No orphan worktrees; lane relationship to origin/main known
#   5. Mirror quarantine marker still in place
#   6. Recovery backups still on disk
#
# Exit 0 = clean; exit 1 = hygiene drift (printed with FIX hints).
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

echo "== 1. canonical repository identity =="
COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
TOPLEVEL="$(git rev-parse --show-toplevel)"
# Mirror is a SIBLING of the repo's top-level parent (~/code/hermes-fleet vs
# ~/code/hermes-fleet-ios). Derive from the common dir so this works from any
# worktree: strip "/.git" then take the parent directory.
REPO_HOME="$(dirname "${COMMON_DIR%/.git}")"
case "$COMMON_DIR" in
  */code/hermes-fleet/.git) ok "git common dir is the canonical repo" ;;
  *) bad "this checkout is NOT canonical: $COMMON_DIR (mirror? wrong dir?)" ;;
esac
test -f "$REPO_HOME/hermes-fleet-ios/STOP-DO-NOT-BUILD-HERE.md" \
  && ok "mirror quarantine marker present" \
  || bad "mirror quarantine marker MISSING ($REPO_HOME/hermes-fleet-ios/STOP-DO-NOT-BUILD-HERE.md)"

echo "== 2. worktree topology =="
MAP="$(git worktree list --porcelain)"
COUNT=$(grep -c '^worktree ' <<<"$MAP")
if [ "$COUNT" -le 4 ]; then ok "$COUNT worktrees (lean)"; else bad "$COUNT worktrees (bloat — prune stale ones)"; fi
if grep -q "^worktree ${REPO_HOME}/hermes-fleet\$" <<<"$MAP"; then
  ok "root worktree present (${REPO_HOME}/hermes-fleet)"
else
  bad "root worktree MISSING (${REPO_HOME}/hermes-fleet) — run: git worktree add <path>"
fi

echo "== 3. every worktree clean =="
while IFS= read -r wt; do
  wt="${wt#worktree }"
  # A listed worktree whose directory is gone (prunable) makes `git status`
  # fail: that failure IS the hygiene drift this check exists to surface, so
  # it must be reported — never silently counted as clean.
  if ! status_out="$(git -C "$wt" status --porcelain 2>/dev/null)"; then
    bad "unreadable worktree: $wt (directory missing/stale — run: git worktree prune)"
    continue
  fi
  dirty=0
  if [ -n "$status_out" ]; then
    dirty="$(grep -v '^?? build/' <<<"$status_out" | wc -l | tr -d ' ')"
  fi
  if [ "$dirty" -eq 0 ]; then ok "clean: $wt"; else bad "$dirty uncommitted path(s) in $wt (commit or recover them)"; fi
done < <(grep '^worktree ' <<<"$MAP")

echo "== 4. stashes =="
SN=$(git stash list | wc -l | tr -d ' ')
[ "$SN" -eq 0 ] && ok "no stashes" || bad "$SN stash(es) hoarded — apply or drop deliberately"

echo "== 5. local branches (expect main + active lane only) =="
BN=$(git for-each-ref --format='%(refname:short)' refs/heads/ | wc -l | tr -d ' ')
if [ "$BN" -le 3 ]; then ok "$BN local branches"; else
  bad "$BN local branches:"; git branch --format='    %(refname:short) -> %(objectname:short)' | sed 's/^/    /'
fi

echo "== 6. lane vs origin =="
git fetch --quiet origin 2>/dev/null
AHEAD=$(git rev-list --count "origin/main..$(git branch --show-current 2>/dev/null || echo main)" 2>/dev/null || echo '?')
echo "  info: current branch is $AHEAD commit(s) ahead of origin/main (expected >0 mid-lane; 0 after merge)"

echo "== 7. recovery backups =="
ls -d "$HOME"/fleet-recovery-* >/dev/null 2>&1 && ok "recovery backup dir present" || echo "  info: no fleet-recovery-* dir (fine if none expected)"

echo
echo "HYGIENE: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
