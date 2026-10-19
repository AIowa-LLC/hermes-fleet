#!/bin/bash
# The private denylist must fail closed: absent, empty, malformed and matching
# denylists all fail when required; a valid non-matching one passes.
set -u
cd "$(dirname "$0")/.."
T="$(mktemp -d "${TMPDIR:-/tmp}/hf_guard_denylist_test.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
FAILS=0
run() { # name expect(0|1) file
  HF_PUBLIC_SAFETY_DENYLIST_FILE="$3" HF_PUBLIC_SAFETY_REQUIRE_PRIVATE=1 bash scripts/public_safety_guard.sh >"$T/out" 2>&1; rc=$?
  if [ "$rc" = "$2" ]; then echo "PASS  $1"; else echo "FAIL  $1 (rc=$rc, expected $2)" >&2; FAILS=$((FAILS+1)); fi
}
# Sentinels are assembled at runtime so this tracked file never contains them
# (the guard scans every tracked file except itself).
SENT="zz$(printf 'z')-no-such-$(printf 'val')ue-zzz"
printf '%s\n' "$SENT" > "$T/ok.txt";           run "valid non-matching denylist passes" 0 "$T/ok.txt"
printf '(\n' > "$T/bad.txt";                               run "malformed regex fails closed" 1 "$T/bad.txt"
printf '[unclosed\n' > "$T/bad2.txt";                      run "unclosed bracket fails closed" 1 "$T/bad2.txt"
printf '# only a comment\n\n' > "$T/empty.txt";            run "comment-only denylist fails when required" 1 "$T/empty.txt"
run "absent denylist fails when required" 1 "$T/missing.txt"
HIT="Hermes Fl$(printf 'ee')t"; printf '%s\n' "$HIT" > "$T/hit.txt";                    run "matching denylist fails" 1 "$T/hit.txt"
# A matching private value must never be echoed into the output.
grep -qF "$HIT" "$T/out" && { echo "FAIL  private value echoed" >&2; FAILS=$((FAILS+1)); } || echo "PASS  matched private value is not echoed"
echo "guard denylist: $FAILS failure(s)"; [ "$FAILS" = 0 ]
