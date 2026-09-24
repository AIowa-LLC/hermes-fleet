# Hermes Fleet release-readiness audit — 2026-09-18

Status: **preparation evidence only**. This document records what was
verified against the GitHub snapshot and what remains dependent on the final
local build. It is not a release note, RC approval, TestFlight submission, or
availability announcement.

## Baseline and boundaries

- Repository: `AIowa-LLC/hermes-fleet`
- Default branch: `main`
- Audited GitHub snapshot: `d0f607b418f2eb75c3f71cbcaaa48a14f5e0ecbf`
- Source snapshot version/build: `0.2.0` / `32`
- Branch used for this work: `codex/fleet-parallel-release-readiness`
- Open issues at baseline: #13, #14, #15, #18, #50, #51
- Open PR at baseline: #46; no other open PR was listed

The checkout was created fresh from GitHub. No active local development
worktree was fetched, inspected, synchronized, rebased, or modified.

## Verified repository work

The following was already present and was reviewed rather than reimplemented:

- app-target `HermesFleetApp/PrivacyInfo.xcprivacy` with a UserDefaults
  `CA92.1` declaration;
- source/privacy-manifest validators and positive/negative contract tests;
- SHA-pinned release/archive/export inspection tooling;
- reviewer v2 container architecture, secret-free launcher, containment probes,
  provider allowlist, and off-network check;
- physical-device/live-gateway RC checklist and public-safe evidence template;
- draft release notes and reviewer metadata package.

This branch adds or improves the independent documentation package:

- `docs/release/BETA-METADATA.md` — known feedback/review contacts filled in,
  reviewer onboarding, known limitations, Apple field references, and explicit
  destination/owner gates;
- `docs/release/REVIEWER-ENVIRONMENT.md` — current status distinguishes the
  checked-in design and historical QA evidence from a provisioned review
  environment;
- `docs/release-preflight.md` — provenance, clean-source, safe-check, and
  upload/export-compliance boundaries made explicit;
- `docs/release/RC-ACCEPTANCE-v1.md` — automated, physical-device, and
  live-gateway evidence types separated, with expected results for every
  environmental suite;
- `docs/privacy-manifest.md` — source-snapshot call sites, current dependency
  inspection limits, Apple references, and final-archive handoff;
- `docs/release/SYNC-HANDOFF.md` — final local-to-GitHub synchronization
  inputs, conflict surfaces, validation sequence, and issue evidence gates;
- `docs/release/PR-46-REVIEW.md` — complete diff review and disposition;
- this audit and the documentation index links.

## Validation results

These are repository-only results. They do not prove a final release build.

| Check | Result |
| --- | --- |
| Privacy manifest source validator | PASS |
| Required-reason source audit | PASS — 24 UserDefaults hits; zero hits for file timestamp, system boot time, disk space, and active keyboards |
| Privacy manifest negative/positive tests | PASS |
| Release preflight contract tests | PASS |
| RC repository preflight | PASS — documents, version/build consistency, UI inventory, public-safety guard |
| Shell syntax checks for changed release/privacy/reviewer scripts | PASS |
| XcodeGen drift gate | PASS — `bash scripts/c1_static.sh` and targeted drift check |
| Public-safety guard | PASS — run after staging the changed documentation |
| Working-tree gitleaks scan | PASS — no leaks found |
| Package tests | INCOMPLETE — FleetCore: 415 tests / 0 failures; FleetNetworking test process hung in `xctest` for over two minutes and was stopped; FleetPersistence/FleetSecurity were not reached |

The reviewer preflight remains intentionally not-ready until owner-only
inputs are supplied: it detects unresolved `[TONY: ...]` metadata fields,
requires a real `PRIVACY_POLICY_URL` at invocation time, and holds the
`ITSAppUsesNonExemptEncryption=false` declaration for human confirmation.

## Deliberately not run or not claimed

- `scripts/release_preflight.sh` archive/export: not run. The current host has
  Xcode 27.0 while the repository script intentionally requires Xcode 26.x;
  distribution signing/provisioning credentials are also not in scope.
- Physical iPhone RC acceptance: not run.
- Live Hermes gateway journeys: not run.
- Reviewer container, public tunnel, demo credentials, provider key, or
  off-network review-window check: not provisioned.
- Apple archive validation, App Store Connect upload/processing, TestFlight
  external review, and submission: not performed.
- Issue #50 final source synchronization: explicitly out of scope.

## Public destination verification

- `https://fleet.aiowa.dev`: did not resolve through public DNS from the
  release-preparation environment on 2026-09-18. It must not be represented as
  a working support/marketing destination until rechecked.
- `https://aiowa.dev/privacy`: returned HTTPS 200, but its visible content
  describes the AIowa website. Tony must confirm that it is suitable for the
  app before using it as the App Store Connect privacy-policy URL.
- `https://github.com/AIowa-LLC/hermes-fleet`: responded successfully and is
  the source repository; it is not a substitute for an app support/privacy
  destination.

## Issue status and remaining gates

| Issue | Completed in this preparation pass | Remaining before closure |
| --- | --- | --- |
| #13 | Source audit documented with code locations; manifest and validators reviewed; third-party dependency limitation made explicit. | Re-run after sync; inspect resolved dependencies and final archive; confirm App Store Connect privacy answers and archive validation. |
| #14 | Deterministic SHA/clean-checkout/XcodeGen/archive/export procedure reviewed and documented; contract tests pass. | Run against the exact RC with distribution signing, provisioning inspection, export, artifact inspection, Apple validation, and eventual upload evidence. |
| #15 | Versioned RC checklist, expected results, modality separation, environmental-suite mapping, and public-safe evidence template are present. | Execute on the exact Release build using a physical iPhone and live Hermes gateway; record PASS/FAIL/HOLD evidence. |
| #18 | Reviewer walkthrough, container-isolation design, credential rotation rules, metadata text, and Apple field references are prepared. | Provision only on the dedicated host, run containment/off-network checks, verify the exact access path, keep it available, and privately enter the missing App Store Connect fields. |
| #50 | Synchronization handoff with required inputs, conflicts, dependencies, validation, and GitHub-visible evidence is added. | Wait for final local engineering confirmation and perform the actual synchronization; do not close this issue from documentation alone. |
| #51 | Draft beta description, What to Test, review notes, support/feedback instructions, limitations, and release checklist are internally consistent and remain draft-only. | Reconcile to the final synchronized feature surface, exact version/build, final RC evidence, verified URLs, privacy/export answers, and genuine TestFlight availability. |

## PR #46 disposition

PR #46 is narrowly scoped to failure diagnostics, has green recorded CI and
an approval review, and does not alter release tooling or application code.
Recommendation: merge after explicit owner sequencing approval, or defer until
the final synchronization if the same CI files change. Re-review the combined
diff if synchronization touches `scripts/c1_units.sh` or `.github/workflows/ci.yml`.
See [`PR-46-REVIEW.md`](PR-46-REVIEW.md).

## Owner-only actions

1. Supply a monitored international-format App Review phone number privately.
2. Confirm an app-appropriate privacy-policy URL and restore/verify the
   intended support/marketing destination.
3. Decide whether PR #46 lands before or after Issue #50 synchronization.
4. Confirm the final local build, version/build, exact SHA, export-compliance
   posture, and App Store Connect privacy answers.
5. Provision and operate the isolated reviewer environment during the review
   window.

No item above authorizes upload, submission, release publication, or merging.
