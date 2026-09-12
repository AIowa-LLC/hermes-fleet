# Local development loop (Dev Loop v2)

The development loop is optimized for fast local feedback and a fast hosted
pull-request preflight. The merge queue remains the only authoritative
integration gate: the exact queued candidate is always validated end to end
before it can enter `main`.

## Fast local loop

1. Iterate on a feature branch and run the fast local check:

   ```bash
   make dev-check
   ```

   This runs, in order: static guards (XcodeGen drift, module boundary, theme
   call-site, privacy manifest, public-safety, gitleaks), a simulator build,
   the host package tests, and the focused UI suites selected from the working
   diff. It never runs the complete UI matrix.

   Useful flags:

   ```bash
   bash scripts/dev_check.sh --base main   # diff against an explicit ref
   bash scripts/dev_check.sh --skip-ui     # static + build + packages only
   ```

   The broad local gate is unchanged: `make ci` runs the full C1 validation
   serially.

2. Optional physical-device dogfood, using the existing deployment scripts:

   ```bash
   bash scripts/u4_device.sh
   ```

   Device deployment is environmental validation; see the script's usage for
   its current flags and environment inputs.

3. Push and open the pull request. Hosted CI runs the fast preflight (below).
   When it is green, enter the merge queue.

4. The merge queue runs the complete authoritative C1 validation on the exact
   queued candidate and merges only on a green `CI Gate`.

## What each hosted topology runs

| Event | Static guards | Packages | Hosted units | UI | Required gate |
| --- | --- | --- | --- | --- | --- |
| `pull_request` | yes | yes | yes | focused preflight subset | `CI Gate`, fail-closed |
| `merge_group` | yes | yes | yes | complete 5-shard matrix | `CI Gate`, fail-closed |
| `push` to `main` | yes | yes | yes | complete 5-shard matrix | informational |

### Pull-request UI preflight

The focused subset is computed by `scripts/c1_ui_preflight.sh` from the files
changed against the pull request base:

- test-suite class files map to their own suite;
- product areas map to the deterministic suites that exercise them (the
  ordered table lives in `scripts/c1_ui_preflight.sh`);
- ambiguous or unmapped product changes fall back to a small conservative
  core-journey set;
- docs/tooling-only changes select no UI suites.

The selector is self-tested by `scripts/c1_ui_preflight_test.sh` in the static
job, and every suite it can select is validated against the canonical
inventory in `scripts/c1_ui_matrix.sh`. The preflight trades exhaustiveness
for speed by design; it must never be treated as a substitute for the
merge-group matrix. The merge-group gate is unchanged: static, package,
hosted-unit, and all five UI shards run against every queued candidate.

## Adding a UI suite

1. Add the class to `HermesFleetAppUITests`.
2. Classify it in `scripts/c1_ui_matrix.sh` (`UI_CLASSES` for deterministic
   CI suites; `ENVIRONMENTAL_CLASSES` for live-gateway/local-only suites) —
   the audit fails loudly until every class is classified exactly once.
3. If the suite has a natural source-area trigger, add an ordered rule to
   `scripts/c1_ui_preflight.sh`; otherwise the conservative core fallback
   covers it.

## Safety properties

- The `CI Gate` check is fail-closed in both topologies: every expected
  dependency must report `success`, and the job that must not run for an
  event must report `skipped` (substituted validation fails the gate).
- The workflow is intentionally not path-filtered — the required check never
  disappears.
- Merge-queue candidates are never cancelled by concurrency; the queue still
  validates the exact integration candidate with the full matrix.
- `scripts/ci_gate_policy_check.sh` (static job) fails if the topology above
  is weakened.
