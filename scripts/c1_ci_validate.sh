#!/bin/bash
# C1 CI validation — the authoritative broad repository gate.
#
# Locally (and historically in CI) this runs every phase in sequence:
#   static guards -> package tests -> hosted unit bundle -> deterministic
#   UI matrix -> (summary)
#
# Since the CI parallelization pass, GitHub Actions runs these same phases as
# separate parallel jobs instead of this one monolithic process (the serial
# UI matrix alone needs ~2.5h and blew the old 45-minute job timeout):
#   static-guards  -> scripts/c1_static.sh
#   packages       -> scripts/c1_packages.sh
#   units          -> scripts/c1_units.sh
#   ui-shard (x4)  -> scripts/c1_ui_matrix.sh --shard N --shards 4
#   ci-gate        -> needs: all of the above (workflow-level)
#
# ONE source of validation logic, multiple execution topologies: this script
# invokes the exact phase scripts CI uses — it does not duplicate any gate or
# suite list. `make ci` still runs this end-to-end locally.
#
# Design history (P1-7, t_ea9f4624): the unit bundle and the deterministic UI
# suites MUST be separate xcodebuild invocations — a bare-bundle selector
# mixed with class-level selectors makes xcodebuild drop the bare bundle.
# This is preserved by the phase split (c1_units.sh vs c1_ui_matrix.sh).
set -u
cd "$(dirname "$0")/.."

FAIL=0
note() { printf '\n========== %s ==========\n' "$1"; }

note "PHASE 1/4: static guards"
bash scripts/c1_static.sh || FAIL=1

note "PHASE 2/4: package tests"
bash scripts/c1_packages.sh || FAIL=1

note "PHASE 3/4: hosted unit bundle"
bash scripts/c1_units.sh || FAIL=1

note "PHASE 4/4: deterministic UI matrix (all shards, serial)"
bash scripts/c1_ui_matrix.sh --all || FAIL=1

printf '\n=====================================\n'
printf 'C1 CI validation: %s\n' "$([ $FAIL -eq 0 ] && echo PASS || echo FAIL)"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
