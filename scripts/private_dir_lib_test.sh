#!/bin/bash
# Shared-host and concurrency tests for scripts/private_dir_lib.sh and the
# supported-workflow scripts that use it. All fixtures live in a private
# per-run directory; nothing touches a fixed shared /tmp name.
set -u
cd "$(dirname "$0")/.."
T="$(mktemp -d "${TMPDIR:-/tmp}/hf_private_dir_test.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
FAILS=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1" >&2; FAILS=$((FAILS+1)); }
# shellcheck source=private_dir_lib.sh
. scripts/private_dir_lib.sh

mode_of() { hf__stat_field mode "$1"; }

# 1. Fresh creation is 0700 and owned by us, even under a permissive umask.
( umask 000; hf_private_dir "$T/fresh" >/dev/null ) && [ "$(mode_of "$T/fresh")" = 700 ] \
  && pass "fresh directory is created 0700 under umask 000" || fail "fresh directory mode"

# 2. Re-validating our own directory succeeds (stable across script runs).
hf_private_dir "$T/fresh" >/dev/null && pass "existing private directory is reused" || fail "reuse"

# 3. A pre-created group/world-accessible directory (another user squatting
#    the predictable name) is refused, not silently repaired and used.
mkdir "$T/squat" && chmod 755 "$T/squat"
if hf_private_dir "$T/squat" >/dev/null 2>&1; then fail "755 directory accepted"; else pass "pre-created 755 directory refused"; fi
mkdir "$T/squat777" && chmod 777 "$T/squat777"
if hf_private_dir "$T/squat777" >/dev/null 2>&1; then fail "777 directory accepted"; else pass "pre-created 777 directory refused"; fi

# 4. A symlink (redirecting writes elsewhere) is refused, including when it
#    points at a directory that would itself be valid.
mkdir "$T/target" && chmod 700 "$T/target"
ln -s "$T/target" "$T/link"
if hf_private_dir "$T/link" >/dev/null 2>&1; then fail "symlink accepted"; else pass "symlink to a private directory refused"; fi
ln -s "$T/does-not-exist" "$T/dangling"
if hf_private_dir "$T/dangling" >/dev/null 2>&1; then fail "dangling symlink accepted"; else pass "dangling symlink refused"; fi
[ ! -e "$T/does-not-exist" ] && pass "refused symlink was not followed to create its target" || fail "symlink target created"

# 5. A regular file with the name is refused; empty path is refused.
: > "$T/file"
if hf_private_dir "$T/file" >/dev/null 2>&1; then fail "regular file accepted"; else pass "regular file refused"; fi
if hf_private_dir "" >/dev/null 2>&1; then fail "empty path accepted"; else pass "empty path refused"; fi

# 6. Concurrent first runs converge on one valid directory with no failures.
RACE="$T/race"; : > "$T/race.fail"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  ( hf_private_dir "$RACE" >/dev/null 2>&1 || echo x >> "$T/race.fail" ) &
done
wait
[ ! -s "$T/race.fail" ] && [ "$(mode_of "$RACE")" = 700 ] \
  && pass "12 concurrent first runs all succeed on one 0700 directory" || fail "concurrent creation"

# 7. Names are per-user so two users never contend for one shared name.
case "$(hf_private_name hermes-fleet-live)" in *"-$(id -u)") pass "default name carries the uid";; *) fail "name lacks uid";; esac

# 8. Supported scripts fail closed (exit 2, nothing written) on a bad dir.
BAD="$T/bad-workdir"; mkdir "$BAD" && chmod 755 "$BAD"
for s in l1_ats_check l1_secrets_scan l1_start_serve l1_live_contract l1_live_contract2 l1_live_contract3_lean; do
  out=$(HERMES_FLEET_LIVE_WORKDIR="$BAD" bash "scripts/$s.sh" 2>&1); rc=$?
  if [ "$rc" = 2 ] && [ -z "$(ls -A "$BAD")" ]; then pass "$s refuses a non-private work directory"; else fail "$s rc=$rc wrote=$(ls -A "$BAD")"; fi
done
ln -s "$T/target" "$T/wd-link"
out=$(HERMES_FLEET_LIVE_WORKDIR="$T/wd-link" bash scripts/l1_start_serve.sh 2>&1); rc=$?
[ "$rc" = 2 ] && [ -z "$(ls -A "$T/target")" ] && pass "l1_start_serve refuses a symlinked work directory" || fail "l1_start_serve symlink rc=$rc"

# 9. The launcher refuses an unsafe state directory before touching it.
out=$(REVIEWER_ENV_DIR="$BAD" bash scripts/reviewer_env_launch.sh clean --purge 2>&1); rc=$?
[ "$rc" != 0 ] && [ -d "$BAD" ] && printf '%s' "$out" | grep -q "REFUSING to purge" \
  && pass "reviewer clean --purge refuses a non-private directory before any destructive step" || fail "purge guard rc=$rc"

# 10. The artifact check's default evidence path is inside the private dir.
grep -q 'hf_private_dir "$(hf_private_name hermes-fleet-live)"' scripts/c_artifact_live_check.sh \
  && ! grep -q '/tmp}/c-artifact-evidence' scripts/c_artifact_live_check.sh \
  && pass "c_artifact_live_check default evidence path is private" || fail "c_artifact default path"

echo "private_dir: $FAILS failure(s)"
[ "$FAILS" = 0 ]
