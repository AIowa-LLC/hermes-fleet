# Hermes Fleet release preflight

Issue #14 provides the repository-side release path. It is deterministic by
construction: a run must start from a clean checkout whose `HEAD` equals the
explicit full SHA supplied to the script, and every report/archive is written
under a SHA-specific disposable `build/` directory.

This is procedure, not RC evidence. `RELEASES.md` records the Build 86
submission and the owner's reported public Build 90 availability, including
historical source-to-archive limitations. Current source has advanced through
PR #60; it does not change either distributed binary. Confirm an unused build
number with the release owner before changing `project.yml`, then regenerate
and release the exact reviewed source. No new upload is authorized here.

## Archive and distribution stages

The preflight keeps the Xcode archive and the final distributable artifact
separate:

1. Build and archive the exact reviewed source.
2. Inspect archive provenance and application content. Archive signing, when
   present, is informational at this stage; an Apple-Development or unsigned
   archive is not rejected merely for that reason.
3. Run `xcodebuild -exportArchive`. The release preflight accepts Xcode 26.x
   and 27.x; its export options use `method=app-store-connect`. Distribution
   signing and App Store provisioning are selected during this export step.
4. Inspect the IPA that export actually produced.
5. Optionally run Apple's credentialed validation. Upload and processing are
   never performed by this script.

The default path performs steps 1–4 and reports Apple validation as not run:

```bash
SHA="$(git rev-parse HEAD)"
HF_APPROVED_VERSION="${OWNER_APPROVED_VERSION:?Confirm the release version first}"
HF_APPROVED_BUILD="${OWNER_APPROVED_BUILD:?Confirm the release build number first}"
bash scripts/release_preflight.sh \
  --sha "$SHA" \
  --expected-version "$HF_APPROVED_VERSION" \
  --expected-build "$HF_APPROVED_BUILD"
```

Archive inspection verifies the bundle identifier, marketing version, build
number, iPhone/iPad device family, iOS deployment target, iPhoneOS platform,
`DTXcode`/`DTXcodeBuild` provenance, export-compliance metadata, and the
embedded privacy manifest. The exported IPA inspector additionally verifies
the actual IPA's bundle metadata, distribution signing authority and team,
application identifier, signed entitlements, App Store provisioning posture,
absence of device-limited or `get-task-allow` state, and embedded privacy
manifest.

## Required provenance record

Before invoking the preflight, record the full candidate SHA and confirm the
checkout is the intended release source. The release record must include:

- full Git SHA and commit subject;
- `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from `project.yml`;
- bundle identifier, target device family, deployment target, and Xcode
  version;
- archive path and the exact preflight report path; and
- final archive/export/validation results, with unavailable credential-gated
  steps marked `NOT RUN` or `BLOCKED` rather than inferred as pass.

The candidate must be a clean checkout of the approved, green `main` source.
Run `git fetch origin`, inspect the current `origin/main`, and do not archive
from a dirty worktree or an unreviewed development branch. Run
`bash scripts/xcodegen_drift_gate.sh` before the archive; it regenerates from
`project.yml` and fails if the committed Xcode project drifts.

Every archive entry point runs `scripts/release_lineage_guard.sh` before
project generation or Xcode archive work. It reads the approved integration
SHA from committed `docs/release/integration-baseline.sha`, requires that
commit to be present and an ancestor of the exact candidate HEAD, and rejects
tracked or untracked source changes. The initial pin is the accepted PR #60
integration at `788907a5ed591ad8b59319fddddf0d6d58dd57d4`. Updating it requires a
reviewed protected-main change. Use a full-history checkout; missing objects
in a shallow clone fail closed. This ancestry floor does not replace current
candidate CI or release acceptance evidence.

The compatibility `archive_and_export.sh` helper requires an explicit SHA and
`main` or `release/*` branch. It uses the same clean-tree/ancestry guard and
has no dirty override or machine-specific checkout requirement. Its build
argument must be an owner-approved unused number. Prefer the full preflight
for generation, privacy, signing inspection, and Apple validation.

## Toolchain evidence

On 2026-09-29 the selected local host reports Xcode 27.0 (27A266a).
`release_preflight.sh` already accepts majors 26 and 27; the older Xcode-26-only
prose was stale. The export plist uses `app-store-connect`. No policy expansion
is needed for this host. Acceptance of the toolchain version is not proof of a
signed RC: record clean generation, Release build/archive, exported artifact
inspection, Apple validation, and ASC processing on the exact candidate and
selected toolchain before declaring release readiness. Any future major-version
policy change needs those results and contract coverage in a reviewed PR.
Ordinary feature-development readiness remains separate from these release
credentials and artifact checks.

## Machines without distribution export credentials

To prove the Release archive structure while explicitly stopping before
distribution export, use:

```bash
bash scripts/release_preflight.sh --sha "$SHA" --structure-only
```

This mode is structural evidence only. It does not claim distribution signing,
Apple validation, TestFlight readiness, or App Store acceptance. A normal
preflight that reaches export but cannot produce a distributable IPA exits with
a blocked distribution-stage result; that is an unavailable certificate,
profile, or account gate, not an archive-stage signing verdict.

## Apple validation and upload

When a signed export is ready, a release owner may opt into local IPA
validation with an App Store Connect API key:

```bash
export ASC_API_KEY_ID="..."
export ASC_API_ISSUER_ID="..."
export ASC_API_KEY_PATH="/secure/path/AuthKey_KEYID.p8"
HF_APPROVED_VERSION="${OWNER_APPROVED_VERSION:?Confirm the release version first}"
HF_APPROVED_BUILD="${OWNER_APPROVED_BUILD:?Confirm the release build number first}"
bash scripts/release_preflight.sh \
  --sha "$SHA" \
  --expected-version "$HF_APPROVED_VERSION" \
  --expected-build "$HF_APPROVED_BUILD" \
  --validate \
  --allow-provisioning-updates
```

`ASC_API_KEY_PATH` is a real input: it is passed to `xcodebuild` through its
supported `-authenticationKeyPath`/ID/issuer options and to the selected Xcode
26.x or 27.x toolchain's `xcrun altool --validate-app` through
`--p8-file-path`. The private key must be
outside the repository, have owner-only permissions, and never appear in
shell history, logs, CI output, or a committed file. The script never prints
key material and never uploads. Organizer or an equivalent credentialed
App Store Connect upload and subsequent processing acceptance remain deliberate
external release actions.

The script intentionally stops before upload. Apple still requires the
uploaded beta build's export-compliance information to be answered or linked
to approved documentation in TestFlight. See Apple's
[beta export-compliance procedure](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds).

## Build-number retry policy

`CURRENT_PROJECT_VERSION` in `project.yml` is the source of truth. Builds recorded as uploaded or processed are consumed; the ledger includes
Builds 86 and 90. Local source build counters do not prove upload status. For any new upload or retry after upload/processing, the
release owner must confirm the build number before `project.yml` changes; then
regenerate the project and release the exact resulting Git SHA. Never reuse a
released number or silently auto-increment during archive. A retry that only
changes credentials or validation flags may reuse a not-yet-uploaded archive;
once Apple has accepted a build into processing, a new owner-approved number
is required.

Issue #17 additionally requires release candidates to originate only from a
fully green `main`; this preflight does not override that integration gate.

## Safe repository-only checks

These checks can run before the final RC without signing, upload, device, or
live-gateway access:

```bash
bash scripts/xcodegen_drift_gate.sh
bash scripts/privacy_manifest_validate.sh
bash scripts/privacy_required_reason_audit.sh
bash scripts/release_preflight_contract_test.sh
bash scripts/rc_preflight.sh
bash scripts/public_safety_guard.sh
gitleaks detect --source . --no-git
```

`rc_preflight.sh` runs the public-safety guard with
`HF_PUBLIC_SAFETY_REQUIRE_PRIVATE=1`: it FAILS unless the private, out-of-repo
denylist is configured (`HF_PUBLIC_SAFETY_DENYLIST_FILE`, or
`~/.config/hermes-fleet/public-safety-denylist.txt`). The public script holds
only generic residue checks; maintainer-specific values are never committed.

They prove repository invariants only. They do not prove distribution signing,
archive contents, Apple's validation result, backend availability, or
TestFlight review acceptance.
