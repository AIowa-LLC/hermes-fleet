# Privacy manifest and required-reason API audit

Issue #13 records the privacy posture of the shipping `HermesFleetApp` target.
The audited app target owns the manifest at
`HermesFleetApp/PrivacyInfo.xcprivacy`; `project.yml` adds that file to the
target resources and XcodeGen produces the corresponding resource phase.

Audit snapshot: 2026-09-18 at repository `d0f607b`. The source audit is
evidence for this GitHub snapshot only. Re-run it after Issue #50
synchronization and validate the built/archive copy before using it for App
Store Connect answers.

## Scope and dependency graph

The shipping target links the local `FleetCore`, `FleetNetworking`,
`FleetSecurity`, `FleetPersistence`, and `FleetUI` packages. `FleetUI` links
the pinned SwiftStreamingMarkdown revision
`5f7c04e0558df6146f90d482edb62cb456986bda`.

The repository does not commit `Package.resolved` or SwiftPM's checkout
directory (`Package.resolved` is ignored), so a fresh clone cannot prove the
resolved transitive dependency graph or inspect third-party bundle manifests.
SwiftPM resolves that graph during the build. A final RC audit must inspect
the resolved graph and every embedded framework/library or package bundle in
the archive. The app manifest cannot substitute for a third-party SDK
manifest when Apple requires the SDK to carry its own declarations.

The source audit covers production Swift in `HermesFleetApp/` and every local
package `Sources/` directory. Tests, documentation, comments, and derived
build products are excluded from call-site findings.

## Findings and declarations

| Required-reason category | Finding | Declaration |
| --- | --- | --- |
| UserDefaults | Used for app-owned settings, navigation state, profile selection, and other app-private preferences. No app-group or system-domain access. | `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1` |
| File timestamp | No production call sites. | None |
| System boot time | No production call sites. | None |
| Disk space | No production call sites. | None |
| Active keyboards | No production call sites. | None |

### UserDefaults source locations

The current scanner reports 24 production hits, all in app-owned defaults
used for local settings/state. Line numbers are for the audited snapshot and
may move after synchronization:

| File | Lines |
| --- | --- |
| `HermesFleetApp/FleetServiceGraph.swift` | 91, 223 |
| `Packages/FleetUI/Sources/FleetUI/AppEnvironment.swift` | 454 |
| `Packages/FleetUI/Sources/FleetUI/AppLockController.swift` | 101, 108 |
| `Packages/FleetUI/Sources/FleetUI/ConnectionIntentStore.swift` | 12, 15 |
| `Packages/FleetUI/Sources/FleetUI/ConversationToolingViewModel.swift` | 64, 100, 102 |
| `Packages/FleetUI/Sources/FleetUI/FleetAccent.swift` | 51, 53 |
| `Packages/FleetUI/Sources/FleetUI/FleetAppearance.swift` | 45, 47 |
| `Packages/FleetUI/Sources/FleetUI/FleetTabView.swift` | 81, 99 |
| `Packages/FleetUI/Sources/FleetUI/FleetThemePalette.swift` | 552, 555, 582 |
| `Packages/FleetUI/Sources/FleetUI/GatewayResourceView.swift` | 64, 71, 207 |
| `Packages/FleetUI/Sources/FleetUI/KanbanBoardSelectionStore.swift` | 17, 20 |

The source also reads local file-size and file-attribute values for attachment
handling, but the current Apple required-reason table audited by the scanner
does not list those calls as a required-reason category. Recheck any new API
use against Apple's current table rather than expanding the manifest by guess.

Fleet does not declare collected data or tracking in this manifest:
`NSPrivacyCollectedDataTypes` is empty and `NSPrivacyTracking` is false.
Network access to a gateway configured by the user is Fleet functionality, not
tracking or a reason to add a fabricated collection declaration here.

The declaration follows Apple's required-reason guidance: `CA92.1` is limited
to information accessible only to this app. A future use of an app group,
file metadata, boot time, disk-space, or active-keyboard API must update both
the source manifest and the audit rationale with the exact approved reason.

The source scanner's API table is pinned to Apple's current
[`NSPrivacyAccessedAPIType` documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
Apple also states that required-reason APIs used by third-party SDKs must be
declared in the SDK's own privacy manifest:
[`Describing use of required reason API`](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api),
[`Privacy manifest files`](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files), and
[`TN3183`](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest).
The current File Timestamp list includes `creationDate`, `modificationDate`,
`fileModificationDate`, `contentModificationDateKey`, `creationDateKey`,
`getattrlist`, `getattrlistbulk`, `fgetattrlist`, `stat`, and `fstat`. The
current Disk Space list includes the four capacity keys, `systemFreeSize`,
`systemSize`, `statfs`, `statvfs`, `fstatfs`, `fstatvfs`, `getattrlist`,
`fgetattrlist`, and `getattrlistat`. `lstat` and `fstatat` were specifically
reviewed but are not listed in Apple's current table, so the audit does not
pretend they are covered required-reason APIs. Shared APIs are mapped to every
Apple category that lists them.

Third-party SDK manifests remain the SDK owners' responsibility; the app
manifest does not substitute for a manifest inside an SDK bundle.

## Deterministic checks

Run from the repository root:

```bash
bash scripts/privacy_manifest_validate.sh
bash scripts/privacy_required_reason_audit.sh
bash scripts/privacy_required_reason_audit_test.sh
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

## Final-RC dependency handoff

After source synchronization, record the exact resolved SwiftPM graph and
inspect the archive for every embedded framework, dynamic library, and package
bundle. For each item, record whether it contains `PrivacyInfo.xcprivacy`,
whether it uses a required-reason API, and whether Apple lists it among SDKs
that require a manifest/signature. The final archive—not this source-only
audit—is the evidence for the shipping binary.
