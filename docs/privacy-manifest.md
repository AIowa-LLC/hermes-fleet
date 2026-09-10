# Privacy manifest and required-reason API audit

Issue #13 records the privacy posture of the shipping `HermesFleetApp` target.
The audited app target owns the manifest at
`HermesFleetApp/PrivacyInfo.xcprivacy`; `project.yml` adds that file to the
target resources and XcodeGen produces the corresponding resource phase.

## Scope and dependency graph

The shipping target links the local `FleetCore`, `FleetNetworking`,
`FleetSecurity`, `FleetPersistence`, and `FleetUI` packages. `FleetUI` links
the pinned SwiftStreamingMarkdown revision
`5f7c04e0558df6146f90d482edb62cb456986bda` and its resolved transitive graph:

- `swift-markdown` 0.7.3
- `swift-cmark` 0.8.0
- `swift-syntax` 603.0.2
- `HighlightSwift` revision `99c431b38a1444a5fd6a4978307fbbefe3a7af53`
- `iosMath` revision `ba9ab7729b151329c54fd895a7c1859981d9484c`
- `SwiftUI-Shimmer` 1.5.1
- `Equatable` 1.4.1

The audit covers production Swift in `HermesFleetApp/` and every local
package `Sources/` directory. Tests, documentation, comments, and derived
build products are excluded from call-site findings. The pinned third-party
checkouts were also inspected for privacy manifests and required-reason API
call patterns; no manifest or matching production-source usage was found.

## Findings and declarations

| Required-reason category | Finding | Declaration |
| --- | --- | --- |
| UserDefaults | Used for app-owned settings, navigation state, profile selection, and other app-private preferences. No app-group or system-domain access. | `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1` |
| File timestamp | No production call sites. | None |
| System boot time | No production call sites. | None |
| Disk space | No production call sites. | None |
| Active keyboards | No production call sites. | None |

Fleet does not declare collected data or tracking in this manifest:
`NSPrivacyCollectedDataTypes` is empty and `NSPrivacyTracking` is false.
Network access to a gateway configured by the user is Fleet functionality, not
tracking or a reason to add a fabricated collection declaration here.

The declaration follows Apple's required-reason guidance: `CA92.1` is limited
to information accessible only to this app. A future use of an app group,
file metadata, boot time, disk-space, or active-keyboard API must update both
the source manifest and the audit rationale with the exact approved reason.

Third-party SDK manifests remain the SDK owners' responsibility; the app
manifest does not substitute for a manifest inside an SDK bundle.

## Deterministic checks

Run from the repository root:

```bash
bash scripts/privacy_manifest_validate.sh
bash scripts/privacy_required_reason_audit.sh
bash scripts/xcodegen_drift_gate.sh
```

The validator checks the source file's type, exact root keys, malformed or
duplicate entries, approved reason values, absence of collection/tracking, and
the exact audited category set. When an archive or built app exists, prove the
shipping copy rather than trusting the source file alone:

```bash
bash scripts/privacy_manifest_validate.sh \
  --built-app build/release-preflight/HermesFleetApp.xcarchive/Products/Applications/HermesFleetApp.app
```

The release preflight in Issue #14 reuses this same validator for archive
proof. It must fail if the manifest disappears or changes shape in the
shipping bundle.
