# Integration-safe main

Hermes Fleet treats `main` as the release-candidate source. Required merge
checks establish fast, high-signal confidence for the exact candidate. The
complete deterministic UI matrix remains available as deep validation without
making each individual UI flake a universal integration lock.

## Merge contract

Every pull request targeting `main` follows this sequence:

1. The pull request workflow runs static, privacy, safety, and security guards;
   package tests; the full hosted unit suite; and a changed-area UI preflight
   selected against the pull request base.
2. The pull request stays current with `main`; strict required-status-check
   enforcement causes `CI Gate` to run again after `main` advances.
3. The pull request enters GitHub's native merge queue. GitHub creates a
   merge-group candidate containing the queued integration state.
4. The `merge_group` event runs the same static, package, and hosted-unit
   checks, repeats changed-area UI selection against the merge-group base, and
   runs four exact core critical methods against the queued candidate. When
   present in the candidate, the Build 87 deep-history room method runs too.
5. `CI Gate` passes only when every dependency expected for that event reports
   `success`, and an event-inapplicable job reports `skipped`. A failure,
   cancellation, or missing expected validation blocks the queue.
6. GitHub merges the candidate through the queue after the required check and
   configured thread-resolution requirements are satisfied. The solo-
   maintainer policy does not require a second approving review or approval
   from the last pusher.

The critical smoke covers fresh-install launch, Bots roster navigation,
gateway-to-conversation send/stream, and a basic hosted-room open/send. It runs
exact methods from `F3Onboarding`, `U3TabNavigation`, `HermesFleetHappyPath`,
and `RoomChat`. When the candidate includes the Build 87 deep-history room
test, it also runs
`FOS8Accessibility/testGroupConversationOpensAtLatestWithDeepHistory`; that
case guards the known latest-entry product defect. Historical full-suite
timings put the three original smoke suites at about 30 minutes; the
method-level set has not yet been measured as a combined run. The dedicated
job allows 45 minutes.

The workflow is intentionally not path-filtered. A required aggregate check
must not disappear for a docs-only change or any other unmatched path. The
policy guard in `scripts/ci_gate_policy_check.sh` verifies the event topology,
required check name, smoke selection, and fail-closed contract. Merge-group
runs are protected from concurrency cancellation.

## Full UI regression

The complete deterministic Build 87 inventory of 59 suites remains in
`scripts/c1_ui_matrix.sh` with all five shards. It runs nightly and can be
started manually against a selected source ref, including an exact release
candidate, through `.github/workflows/ui-regression.yml`. Runtime-weighted
shard estimates peak near 105 minutes, with a 150-minute timeout per shard.
Each shard uploads xcresults and xcodebuild logs after success or failure. The
`Full UI Regression Gate` is informative and is not required by the main
branch ruleset.

Full-matrix failures still matter and should be triaged from their test
results and artifacts. Confirmed product defects block release. Test-harness
or CI/infrastructure failures should be classified and rerun or repaired in
their own lane; an isolated flaky suite does not automatically block unrelated
repository integration.

## Main and release eligibility

The active `protect-main` ruleset retains deletion and non-fast-forward
protections and requires the `CI Gate` check, strict up-to-date enforcement,
and the native merge queue. It has no bypass actors, requires zero approving
reviews, and does not require last-push approval; resolved review threads and
the other configured protections remain in force. The hosted ruleset is not
versioned in this repository. Direct pushes and merges outside the queue are
not the normal integration path.

If `main` is red after a merge, it is not releasable. A failed `CI Gate` must
be repaired and a new green `main` SHA established before archive or
TestFlight work. Deep UI results inform release confidence, while the release
process still verifies the exact SHA through local validation, archive,
Internal TestFlight, and physical-device checks before public promotion.

## Maintainer verification

Inspect the hosted ruleset with:

```bash
gh api repos/AIowa-LLC/hermes-fleet/rulesets/22489588
```

Verify that the active ruleset targets `refs/heads/main`, requires only the
`CI Gate` status with strict up-to-date enforcement, includes a merge-queue
rule, and retains deletion and non-fast-forward protection. Also verify the
pull-request rule, queue timeout, and empty bypass actor list before changing
release policy. Deep UI regression is deliberately separate from this
required check.
