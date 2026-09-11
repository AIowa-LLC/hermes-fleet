# Hermes Fleet release preflight

Issue #14 provides the repository-side release path. It is deterministic by
construction: a run must start from a clean checkout whose `HEAD` equals the
explicit full SHA supplied to the script, and every report/archive is written
under a SHA-specific disposable `build/` directory.

## Archive and distribution stages

The preflight keeps the Xcode archive and the final distributable artifact
separate:

1. Build and archive the exact reviewed source.
2. Inspect archive provenance and application content. Archive signing, when
   present, is informational at this stage; an Apple-Development or unsigned
   archive is not rejected merely for that reason.
3. Run `xcodebuild -exportArchive`. With the Xcode 26 toolchain, the export
   options use `method=app-store-connect`; distribution signing and App Store
   provisioning are selected during this export step.
4. Inspect the IPA that export actually produced.
5. Optionally run Apple's credentialed validation. Upload and processing are
   never performed by this script.

The default path performs steps 1–4 and reports Apple validation as not run:

```bash
SHA="$(git rev-parse HEAD)"
bash scripts/release_preflight.sh \
  --sha "$SHA" \
  --expected-version 0.2.0 \
  --expected-build 32
```

Archive inspection verifies the bundle identifier, marketing version, build
number, iPhone/iPad device family, iOS deployment target, iPhoneOS platform,
`DTXcode`/`DTXcodeBuild` provenance, export-compliance metadata, and the
embedded privacy manifest. The exported IPA inspector additionally verifies
the actual IPA's bundle metadata, distribution signing authority and team,
application identifier, signed entitlements, App Store provisioning posture,
absence of device-limited or `get-task-allow` state, and embedded privacy
manifest.

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
bash scripts/release_preflight.sh \
  --sha "$SHA" \
  --expected-version 0.2.0 \
  --expected-build 32 \
  --validate \
  --allow-provisioning-updates
```

`ASC_API_KEY_PATH` is a real input: it is passed to `xcodebuild` through its
supported `-authenticationKeyPath`/ID/issuer options and to Xcode 26's
`xcrun altool --validate-app` through `--p8-file-path`. The private key must be
outside the repository, have owner-only permissions, and never appear in
shell history, logs, CI output, or a committed file. The script never prints
key material and never uploads. Organizer or an equivalent credentialed
App Store Connect upload and subsequent processing acceptance remain deliberate
external release actions.

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
