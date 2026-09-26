#!/bin/bash
# Evaluate the CI Gate result contract for one GitHub event topology.
#
# The workflow supplies dependency results through CI_GATE_* variables. Keep
# this executable and dependency-free so the same fail-closed logic can be
# exercised locally by ci_gate_policy_contract_test.sh.
set -euo pipefail

fail() {
  printf 'CI GATE FAIL: %s\n' "$1" >&2
  exit 1
}

require_success() {
  local label="$1"
  local result="$2"
  [ "$result" = "success" ] || fail "$label result is '$result', expected success"
}

require_skipped() {
  local label="$1"
  local result="$2"
  [ "$result" = "skipped" ] || fail "$label result is '$result', expected skipped"
}

EVENT="${CI_GATE_EVENT_NAME:-}"
require_success "static guards" "${CI_GATE_STATIC_RESULT:-}"
require_success "packages" "${CI_GATE_PACKAGES_RESULT:-}"
require_success "hosted units" "${CI_GATE_UNITS_RESULT:-}"

case "$EVENT" in
  pull_request)
    require_success "focused UI preflight" "${CI_GATE_UI_PREFLIGHT_RESULT:-}"
    require_skipped "critical merge smoke" "${CI_GATE_CRITICAL_SMOKE_RESULT:-}"
    ;;
  merge_group)
    require_success "focused UI preflight" "${CI_GATE_UI_PREFLIGHT_RESULT:-}"
    require_success "critical merge smoke" "${CI_GATE_CRITICAL_SMOKE_RESULT:-}"
    ;;
  push)
    require_skipped "focused UI preflight" "${CI_GATE_UI_PREFLIGHT_RESULT:-}"
    require_skipped "critical merge smoke" "${CI_GATE_CRITICAL_SMOKE_RESULT:-}"
    ;;
  *)
    fail "unsupported event topology '$EVENT'"
    ;;
esac

printf 'CI GATE PASS: %s topology satisfies its result contract.\n' "$EVENT"
