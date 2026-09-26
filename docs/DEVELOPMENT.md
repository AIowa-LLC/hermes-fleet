# Development workflow

Use small, protected integrations rather than accumulating several releases on a
long-lived local branch. `main` represents the latest accepted integration;
immutable release tags identify the source actually distributed to testers.
A green integration does not by itself authorize distribution.

## Branches and ownership

| Branch | Purpose |
| --- | --- |
| `main` | Protected integration baseline. Changes arrive only through PRs and the merge queue. Never force-push or directly edit it. |
| `feature/*`, `fix/*`, `ci/*`, `docs/*` | Short-lived branches from current main for one coherent change. |
| `release/*` | Optional frozen release candidate when a candidate must remain unchanged during independent work. |
| `dogfood-next` | Optional temporary integration branch for a coordinated batch, not a mandatory extra merge stage. |

Do not switch, reset, stash, clean, or rebase another worker's active checkout.
Use an isolated worktree or clone. Back up committed source branches promptly;
pushing a source branch is not the same as merging or distributing a build.

## Normal feature loop

1. Record the upstream feature contract and supported gateway behavior. See
   [upstream-compatibility.md](upstream-compatibility.md).
2. Branch from synchronized main and implement one small vertical slice with
   synthetic fixtures and a regression test.
3. Run the relevant local checks, review the diff, and open a focused PR.
4. Require Dev Loop v3 validation on the PR and exact merge candidate.
5. Produce an internal build when useful. Promote only with the appropriate
   source, archive, device, and release evidence and explicit authorization.

Every beta or production bug fix should add a practical regression test. New UI
suites must be registered and mapped deliberately. Do not turn incomplete tests
into passes, delete known regressions, or weaken security boundaries to merge.

## Validation

The required gate includes static/security/project checks, package tests, hosted
units, and coverage-preserving changed-area UI tests. Merge candidates also run
critical smoke. Broad shared-layer changes retain broader validation; the full
nightly/manual suite is not an unconditional lock on every narrow change.
See [dev-loop.md](dev-loop.md) for exact commands and limitations.

## Release provenance and catch-up

Every TestFlight build maps to an exact commit and immutable tag recorded in
[RELEASES.md](../RELEASES.md), with build configuration, archive/IPA provenance,
and acceptance evidence. Follow the actual release tooling and authorization
requirements in [release-preflight.md](release-preflight.md); this document does
not bypass them.

Preserve an already accepted historical release source while reconciling it to
main. Do not rebuild or relabel it merely to make a squash-merge SHA match.
Record the original source and integration SHA separately. Product or build-input
changes during reconciliation require fresh validation. See
[integration-safe-main.md](integration-safe-main.md).
