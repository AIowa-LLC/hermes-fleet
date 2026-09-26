# Safe reconciliation of a validated release

## Keep three facts separate

- Release source: the exact commit used to produce the accepted binary.
- Integration source: the combined candidate tested for a merge into main.
- Distribution state: the archive/build actually uploaded and accepted for the
  intended TestFlight audience.

A successful unit run, clean working tree, archive export, or TestFlight upload
alone does not prove all three. Record each with its own evidence.

## One-time catch-up sequence

1. Leave any active build checkout and existing artifacts untouched. Work in a
   separate clone/worktree and inventory local branches before retiring any.
2. Preserve the clean candidate commit remotely. Mark it as a candidate until
   acceptance is complete; do not create a falsely verified release record.
3. Land the CI-only Dev Loop v3 policy through the existing protected PR/queue
   path. The required `CI Gate` and repository rules stay enabled. No admin
   bypass, fabricated status, force-push, or temporary protection removal.
4. Once the release candidate is accepted, create one authoritative reconciliation
   PR for that accepted product state. Preserve historical release records;
   do not replay every intermediate build as an independent release merge.
5. Compare the candidate with the intended integration source. Audit app code,
   resources, dependencies, generated project state, entitlements, privacy and
   build configuration, not only version numbers or commit titles.
6. Run the required gate on the actual combined candidate. For Build 87+ the
   deep-history group-room latest-entry regression must pass. An ordinary-chat
   scrolling fix is not evidence that the group-room defect is resolved.
7. Merge only after complete required checks and resolution of actual blockers.
   Record both the original release SHA/tag and the squash integration SHA.
8. Retire superseded PRs and branches only after confirming all unique work and
   evidence are accounted for. Never delete another worker's active branch.

## Current migration constraint

The migration started with Build 86 source on main, verified Build 87 source in
PR #54, and subsequent local candidates. PR #54 records a real deep-history
room-opening defect. Changing CI policy does not resolve that product defect or
approve any later candidate. Recheck live repository and build evidence before
performing reconciliation; this document is not a live status report.

The CI-only change may land against the older main without rewriting the active
release candidate. New validation policy is intentionally separate from product
acceptance. Missing evidence means the next phase remains pending.

## Acceptance record

Record the source SHA, source tag, application version/build number, dependency
and configuration identity, archive/IPA identity, upload destination and receipt,
physical-device/Internal TestFlight acceptance, required hosted checks and their
candidate SHAs, known issues, and explicit promotion authorization.

Private signing material, device identifiers, credentials, private endpoints,
and personal filesystem paths must never appear in public evidence. Public
records reference sanitized evidence rather than copying sensitive logs.

## Ongoing branch hygiene

After catch-up, branch from synchronized main, integrate small changes promptly,
and freeze a release candidate separately when needed. Release tags are stable;
main can continue to receive validated work without pretending those commits are
already in TestFlight. Use [upstream-compatibility.md](upstream-compatibility.md)
to turn upstream changes into bounded, testable feature work.
