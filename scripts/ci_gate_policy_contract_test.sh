#!/bin/bash
# Executable contract tests for the event-specific CI Gate semantics.
set -u
cd "$(dirname "$0")/.."

EVAL=scripts/ci_gate_policy_eval.sh
[ -x "$EVAL" ] || { echo "FAIL: missing executable $EVAL"; exit 1; }

FAIL=0

expect_pass() {
  local label="$1"
  shift
  if "$@" "$EVAL" >/dev/null 2>&1; then
    echo "PASS  $label"
  else
    echo "FAIL  $label (expected pass)"
    FAIL=$((FAIL + 1))
  fi
}

expect_fail() {
  local label="$1"
  shift
  if "$@" "$EVAL" >/dev/null 2>&1; then
    echo "FAIL  $label (expected fail)"
    FAIL=$((FAIL + 1))
  else
    echo "PASS  $label"
  fi
}

base=(
  CI_GATE_STATIC_RESULT=success
  CI_GATE_PACKAGES_RESULT=success
  CI_GATE_UNITS_RESULT=success
)

expect_pass "pull request requires focused preflight" \
  env "${base[@]}" CI_GATE_EVENT_NAME=pull_request \
    CI_GATE_UI_PREFLIGHT_RESULT=success CI_GATE_CRITICAL_SMOKE_RESULT=skipped
expect_fail "pull request cannot skip focused preflight" \
  env "${base[@]}" CI_GATE_EVENT_NAME=pull_request \
    CI_GATE_UI_PREFLIGHT_RESULT=skipped CI_GATE_CRITICAL_SMOKE_RESULT=skipped
expect_fail "pull request cannot substitute merge smoke" \
  env "${base[@]}" CI_GATE_EVENT_NAME=pull_request \
    CI_GATE_UI_PREFLIGHT_RESULT=success CI_GATE_CRITICAL_SMOKE_RESULT=success

expect_pass "merge group requires focused preflight and critical smoke" \
  env "${base[@]}" CI_GATE_EVENT_NAME=merge_group \
    CI_GATE_UI_PREFLIGHT_RESULT=success CI_GATE_CRITICAL_SMOKE_RESULT=success
expect_fail "merge group with skipped preflight fails closed" \
  env "${base[@]}" CI_GATE_EVENT_NAME=merge_group \
    CI_GATE_UI_PREFLIGHT_RESULT=skipped CI_GATE_CRITICAL_SMOKE_RESULT=success
expect_fail "merge group with skipped critical smoke fails closed" \
  env "${base[@]}" CI_GATE_EVENT_NAME=merge_group \
    CI_GATE_UI_PREFLIGHT_RESULT=success CI_GATE_CRITICAL_SMOKE_RESULT=skipped

expect_pass "main push intentionally skips merge-only UI" \
  env "${base[@]}" CI_GATE_EVENT_NAME=push \
    CI_GATE_UI_PREFLIGHT_RESULT=skipped CI_GATE_CRITICAL_SMOKE_RESULT=skipped
expect_fail "main push cannot substitute critical smoke" \
  env "${base[@]}" CI_GATE_EVENT_NAME=push \
    CI_GATE_UI_PREFLIGHT_RESULT=skipped CI_GATE_CRITICAL_SMOKE_RESULT=success

expect_fail "any static failure blocks the gate" \
  env CI_GATE_STATIC_RESULT=failure CI_GATE_PACKAGES_RESULT=success CI_GATE_UNITS_RESULT=success \
    CI_GATE_EVENT_NAME=push CI_GATE_UI_PREFLIGHT_RESULT=skipped CI_GATE_CRITICAL_SMOKE_RESULT=skipped
expect_fail "unsupported event fails closed" \
  env "${base[@]}" CI_GATE_EVENT_NAME=workflow_dispatch \
    CI_GATE_UI_PREFLIGHT_RESULT=skipped CI_GATE_CRITICAL_SMOKE_RESULT=skipped

# Negative coverage for each dependency: missing/cancelled/failed jobs must
# never become green through aggregation or matrix cancellation.
for event in pull_request merge_group push; do
  preflight=success; smoke=skipped
  [ "$event" != merge_group ] || smoke=success
  [ "$event" != push ] || preflight=skipped
  for field in STATIC PACKAGES UNITS UI_PREFLIGHT CRITICAL_SMOKE; do
    expected=success
    [ "$field" != UI_PREFLIGHT ] || expected="$preflight"
    [ "$field" != CRITICAL_SMOKE ] || expected="$smoke"
    for actual in success failure cancelled skipped unknown missing; do
      [ "$actual" != "$expected" ] || continue
      value="$actual"
      [ "$actual" != missing ] || value=""
      expect_fail "$event rejects $field=$actual" \
        env "${base[@]}" CI_GATE_EVENT_NAME="$event" \
          CI_GATE_UI_PREFLIGHT_RESULT="$preflight" CI_GATE_CRITICAL_SMOKE_RESULT="$smoke" \
          "CI_GATE_${field}_RESULT=$value"
    done
  done
done

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: CI Gate executable contract tests"
  exit 0
fi
echo "CI Gate executable contract tests: FAIL=$FAIL"
exit 1
