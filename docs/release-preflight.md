# Hermes Fleet release preflight

Issue #14 provides the repository-side release path. It is deterministic by
construction: a run must start from a clean checkout whose `HEAD` equals the
explicit full SHA supplied to the script, and every report/archive is written
under a SHA-specific disposable `build/` directory.

## Signed preflight

Run from a clean checkout after reviewing the exact commit to release:

```bash
SHA="$(git rev-parse HEAD)"
bash scripts/release_preflight.sh \
  --sha "$SHA" \
  --expected-version 0.2.0 \
  --expected-build 32
```

The script verifies XcodeGen/project drift, records the Xcode 26.x version,
checks Release build settings, runs a Release build, creates a generic iOS
archive, and inspects the archive for:

- `com.aiowa.hermesfleet`, marketing version, and monotonically selected build number;
- iPhone + iPad device family (`UIDeviceFamily` 1 and 2), iOS deployment target, and iPhoneOS platform;
- `DTXcode`/`DTXcodeBuild` archive provenance;
- `ITSAppUsesNonExemptEncryption=false` export-compliance metadata;
- the exact `PrivacyInfo.xcprivacy` copy in the archived app;
- code-signing authority, team identifier, and the embedded provisioning profile.

The report and logs are under
`build/release-preflight/<full-sha>/`. The signed path fails if the archive is
ad-hoc or lacks an embedded provisioning profile; that is a release blocker,
not a successful preflight.

## Machines without distribution signing

To prove the Release archive structure while clearly retaining the signing
blocker, use the explicit fallback:

```bash
bash scripts/release_preflight.sh --sha "$SHA" --structure-only
```

This mode still checks the bundle, versions, device family, Xcode metadata,
export compliance, and bundled privacy manifest, but its result is not a
TestFlight-ready artifact. It must not be represented as Apple acceptance.

## Apple validation and upload

The script never uploads. When the signed archive is ready, a release owner
may opt into local IPA export and validation with credentials already installed
in the App Store Connect toolchain:

```bash
export ASC_API_KEY_ID="..."
export ASC_API_ISSUER_ID="..."
export ASC_API_KEY_PATH="/secure/path/AuthKey_KEYID.p8"
bash scripts/release_preflight.sh \
  --sha "$SHA" \
  --expected-version 0.2.0 \
  --expected-build 32 \
  --validate \
  --allow-provisioning-updates
```

The private key must be outside the repository, have owner-only permissions,
and never appear in shell history, logs, CI output, or a committed file. The
validation path passes only after `xcodebuild -exportArchive` produces an IPA
and `xcrun altool --validate-app` accepts it. Organizer or an equivalent
credentialed App Store Connect upload remains a deliberate external release
action and is not claimed by this repository preflight.

## Build-number retry policy

`CURRENT_PROJECT_VERSION` in `project.yml` is the source of truth. For every
new TestFlight upload or retry after a build has been uploaded/processed,
increment it, regenerate with `xcodegen generate`, commit the generated
project, and release a new exact Git SHA. Never overwrite a released build
number or silently auto-increment it during archive. A retry that only changes
credentials or validation flags may reuse a not-yet-uploaded archive; once
Apple has accepted the build into processing, use a new number.

Issue #17 additionally requires release candidates to originate only from a
fully green `main`; this preflight does not override that integration gate.
