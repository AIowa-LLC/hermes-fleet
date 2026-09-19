# PR #46 review — hosted unit failure diagnostics

Reviewed against the current repository snapshot on 2026-09-18. This is a
recommendation, not a merge action.

PR: [#46](https://github.com/AIowa-LLC/hermes-fleet/pull/46)

## Scope and current status

The complete diff is limited to:

- `.github/workflows/ci.yml`: upload a per-run hosted-unit `.xcresult` only
  when the unit phase fails, with seven-day retention and
  `if-no-files-found: ignore`;
- `scripts/c1_units.sh`: add a unique result-bundle path, surface failing test
  case lines before the bounded log tail, and print the result path on failure.

The PR is open, non-draft, mergeable, and has a green recorded CI run:

- static guards: pass;
- package tests: pass;
- hosted unit tests: pass;
- focused UI preflight: pass;
- CI Gate: pass; and
- the complete UI matrix was skipped for the pull-request topology, consistent
  with the repository's documented CI split.

The PR has an approval review with no unresolved review threads.

## Review findings

### Behavior and regression risk

The change preserves the existing unit invocation, pass/fail exit status,
retry behavior, merge protections, and release/upload behavior. It changes
diagnostics only. The result bundle is produced in `/tmp` with a run ID and
process ID, preventing collisions between hosted runs.

### Artifact and sensitive-data risk

The artifact is uploaded only after a unit failure and expires after seven
days. The current unit fixtures inspected in this snapshot use synthetic
values and public/example endpoints; no maintainer credentials or production
gateway details were found in the PR diff. An xcresult can still contain test
logs and attachments, so repository access and failure-log hygiene remain the
appropriate controls. The change does not add a new secret, endpoint, or
credential path.

### Release-tooling interaction

The PR does not touch `rc_preflight.sh`, archive/export tooling, privacy
validation, reviewer-environment scripts, or application source. It does not
prove or change release readiness.

### Synchronization conflict

Issue #50 explicitly identifies `scripts/c1_units.sh` and CI workflow changes
as likely conflict surfaces for the pending local-to-GitHub synchronization.
That is the only material delivery risk found: landing the PR before the sync
would simplify the sync; deferring it avoids forcing a pre-sync merge decision.

## Recommendation

**Merge after explicit owner sequencing approval, or defer until the final
synchronization if the local engineering session is expected to touch the same
CI files.** The PR itself is appropriate and its current CI evidence is green;
it is not a release blocker and should not be merged by this task. If the sync
changes either touched file, re-review the combined diff and re-run the full
required CI topology before merging.
