# Integration-safe main

Hermes Fleet treats `main` as the only release-candidate source. A green pull
request is not enough if another pull request can change the integration base
before it merges.

## Merge contract

Every pull request targeting `main` follows this sequence:

1. The pull request workflow runs the fast Fleet CI Gate: static guards,
   package tests, hosted unit tests, and a focused UI preflight whose suite
   subset is selected from the changed files (`scripts/c1_ui_preflight.sh`).
   The complete five-shard matrix does not run for pull requests.
2. The pull request is kept current with `main`; strict required-status-check
   enforcement causes the gate to run again after `main` advances.
3. The pull request enters GitHub's native merge queue. GitHub creates a
   merge-group candidate containing the queued integration state.
4. The `merge_group` event runs the complete authoritative C1 — static,
   package, hosted-unit, and all five deterministic UI-shard jobs — against
   that exact candidate.
5. The required `CI Gate` check passes only when every dependency expected for
   that event reports `success` and the job that must not run for that event
   reports `skipped`; a failure, a cancellation, or substituted/missing
   validation in either topology therefore blocks the queue.
6. GitHub merges the candidate through the queue after the required checks and
   configured thread-resolution requirements are satisfied. This solo-
   maintainer policy does not require a second approving review or approval
   from the last pusher.

The workflow is intentionally not path-filtered. A required aggregate check
must not disappear for a docs-only change or any other unmatched path. The
policy guard in `scripts/ci_gate_policy_check.sh` fails if the trigger or gate
contract is weakened. Its concurrency policy may supersede ordinary PR
refreshes, but never cancels a `merge_group` run. The serial queue's
`check_response_timeout_minutes` is 240: the five UI jobs each have a
75-minute ceiling, leaving explicit margin for macOS runner capacity while a
candidate waits for its checks.

Dev Loop v2 (the pull request preflight) removes duplicated hosted validation
before merge; it does not weaken the integration gate. The merge queue remains
the only path into `main`, the five-shard matrix still runs on every queued
candidate, and `scripts/ci_gate_policy_check.sh` fails if a pull request ever
substitutes the full matrix for the preflight, if the preflight ever
substitutes for the full matrix, or if either topology stops failing closed.

## Main and release eligibility

The active `protect-main` ruleset retains deletion and non-fast-forward
protections and requires the `CI Gate` check, strict up-to-date enforcement,
and the native merge queue. It has no bypass actors, requires zero approving
reviews, and does not require last-push approval; resolved review threads and
the other configured protections remain in force. Direct pushes and merges
outside the queue are not the normal integration path.

If `main` is ever red after a merge, it is immediately non-releasable. The
failure must be repaired and a new green `main` SHA established before any RC,
archive, or TestFlight action. The release preflight in
`docs/release-preflight.md` does not override this integration gate.

## Maintainer verification

The repository ruleset is GitHub-hosted configuration rather than a versioned
file. Inspect it with:

```bash
gh api repos/AIowa-LLC/hermes-fleet/rulesets/22489588
```

Verify that the returned active ruleset targets `refs/heads/main`, includes
`required_status_checks` for `CI Gate` with
`strict_required_status_checks_policy: true`, includes a `merge_queue` rule,
and retains `deletion` and `non_fast_forward`. Verify that the pull-request
rule has `required_approving_review_count: 0` and
`require_last_push_approval: false`, that the queue response timeout is 240
minutes, and that `bypass_actors` is empty before changing release policy.

The merge-group proof for this remediation uses a disposable PR with a
deterministic failure enabled only for `merge_group`; it is queued only long
enough to observe the merge-group workflow and fail-closed `CI Gate`, then is
removed/closed without merging and the temporary branch is deleted. Main's
SHA is checked before and after the exercise.
