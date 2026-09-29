#!/usr/bin/env bash
# Fail closed unless HEAD contains the reviewed integration baseline pinned in
# docs/release/integration-baseline.sha. The pin is read from the committed
# tree so a dirty-worktree override cannot replace the approved baseline. A
# release archive must also come from a clean tree so uncommitted files cannot
# silently alter the packaged source.
set -euo pipefail

fail() {
  echo "RELEASE-LINEAGE-FAIL: $*" >&2
  exit 1
}

CANDIDATE_SHA="${1:-}"
[[ "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "candidate must be a full lowercase Git SHA-1"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse --verify HEAD 2>/dev/null)" || fail "cannot resolve HEAD"
[[ "$CANDIDATE_SHA" == "$HEAD_SHA" ]] || fail "candidate $CANDIDATE_SHA is not HEAD $HEAD_SHA"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)" ]]; then
  fail "release source worktree must be clean"
fi

BASELINE_FILE="docs/release/integration-baseline.sha"
BASELINE_SHA="$(git -C "$REPO_ROOT" show "HEAD:$BASELINE_FILE" 2>/dev/null)" ||
  fail "committed $BASELINE_FILE is missing"
[[ "$BASELINE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "committed $BASELINE_FILE must contain exactly one full lowercase Git SHA-1"
git -C "$REPO_ROOT" cat-file -e "${BASELINE_SHA}^{commit}" 2>/dev/null ||
  fail "pinned baseline $BASELINE_SHA is not available as a commit"

if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$BASELINE_SHA" "$CANDIDATE_SHA"; then
  fail "candidate $CANDIDATE_SHA does not descend from approved integration baseline $BASELINE_SHA"
fi

echo "Approved release integration baseline: $BASELINE_SHA"
echo "Candidate ancestry: PASS ($CANDIDATE_SHA)"
