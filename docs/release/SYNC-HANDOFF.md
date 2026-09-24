# Final local-to-GitHub synchronization handoff

This handoff supports Issue #50. It is intentionally source-synchronization
work only; it does not pull from, inspect, or modify the active local Hermes
development worktree and does not declare that the current GitHub snapshot is
the final release candidate.

## Required information from the final local build

Before opening the synchronization PR, record the following in the PR body and
in the public-safe RC evidence template:

- full candidate Git SHA and the source branch/ref it came from;
- `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, bundle identifier, and
  deployment target from the final build;
- Xcode version and the exact project-generation command/result;
- whether the candidate includes or supersedes PR #46;
- the final feature/known-limitation delta against `docs/features.md` and
  `docs/navigation.md`; and
- the first post-sync validation results, with physical-device, signing,
  gateway, and App Store Connect steps still marked `NOT RUN` until actually
  executed.

Do not include UDIDs, credentials, private endpoints, provider keys, signing
identifiers, personal paths, or private gateway evidence.

## Likely conflict surfaces

Resolve these deliberately rather than interleaving unrelated merges:

| Surface | Why it may conflict | Required resolution |
| --- | --- | --- |
| `project.yml` and `HermesFleetApp.xcodeproj/project.pbxproj` | The project file is generated output and must match the final source configuration. | Treat `project.yml` as authoritative, run XcodeGen, and review drift before committing both. |
| `scripts/c1_units.sh` | PR #46 changes this file; the build-41 synchronization may also change CI scripts. | Decide PR #46 first or explicitly defer it, then resolve one coherent version. |
| `.github/workflows/ci.yml` | PR #46 adds failure-only xcresult upload behavior; source synchronization may touch CI topology. | Preserve existing gate semantics and re-run workflow checks after the final merge path is known. |
| `HermesFleetApp/PrivacyInfo.xcprivacy` and `docs/privacy-manifest.md` | Required-reason declarations must match the final source and dependency graph. | Re-run the source audit and inspect the archive; do not copy declarations from this snapshot blindly. |
| `docs/features.md`, `README.md`, and release metadata | The local build may add, remove, or rename user-visible surfaces. | Reconcile claims against source and the installed final build; keep status unpublished until TestFlight is live. |
| `docs/release/*` | This branch adds independent launch-preparation docs while the final source may add release notes or evidence. | Merge content intentionally and retain the no-secrets/no-premature-claims rules. |

## Dependencies that must be resolved first

1. The local engineering session confirms that its candidate is final.
2. `origin/main` is fetched and any remote changes are reviewed.
3. The owner decides whether PR #46 is merged before synchronization or
   deferred until after it; this branch does not make that decision.
4. The synchronized tree passes XcodeGen drift, static safety/privacy checks,
   gitleaks, package tests, hosted unit tests, and the applicable UI topology.
5. A fresh exact-SHA Release archive is produced before any TestFlight claim.

## Post-sync validation sequence

Run from a clean checkout of the synchronization result:

```bash
git fetch origin
git status --short --branch
xcodegen generate
bash scripts/xcodegen_drift_gate.sh
bash scripts/c1_static.sh
bash scripts/c1_packages.sh
bash scripts/c1_units.sh
bash scripts/c1_ui_preflight.sh
bash scripts/privacy_required_reason_audit.sh
bash scripts/rc_preflight.sh
```

Then, only on the approved RC and with the required owner approvals:

1. run `scripts/release_preflight.sh` with the exact full SHA and expected
   version/build;
2. inspect the archive/exported artifact and privacy manifest;
3. execute `docs/release/RC-ACCEPTANCE-v1.md` on the physical device and live
   Hermes gateway;
4. provision and verify the isolated reviewer environment using the private
   endpoint/access path; and
5. reconcile App Store Connect privacy, export-compliance, review contact,
   support URL, and beta metadata fields.

No upload, TestFlight submission, or public announcement is implied by the
commands above.

## GitHub-visible evidence required before closing dependent issues

| Issue | Evidence required on GitHub |
| --- | --- |
| #13 | Final source audit, valid manifest in the app target, archive copy validation, and third-party dependency/privacy review. |
| #14 | Exact-SHA preflight report showing archive, distribution export, artifact inspection, and Apple validation results; upload/processing evidence for full closure. |
| #15 | Completed RC checklist plus public-safe evidence report naming the exact SHA/version/build and physical-device/live-gateway results. |
| #18 | Reviewer environment reachability/containment evidence and completed App Store Connect metadata; credentials remain private. |
| #50 | Sync PR merged to `main`, generated project drift clean, and post-sync validation attached. |
| #51 | Release notes and checklist reconciled to the final RC, with no premature availability claim. |
