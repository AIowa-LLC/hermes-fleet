# Extension kit

Planned reach surfaces (Notification Service Extension, widgets, Live Activity,
Control Center controls, share extension) run in separate, memory-limited
processes. They cannot link `HermesFleetApp`, `AppEnvironment`, FleetUI, or
FleetNetworking's WebSocket stack. The extension kit is the narrow, safe layer
they share with the app.

## What exists

| Piece | Where | Purpose |
| --- | --- | --- |
| `FleetClientKit` | `Packages/FleetClientKit` | Extension-safe package: shared configuration, shared container, snapshot store, one-shot HTTPS JSON-RPC helper with SPKI pin verification |
| `FleetSharedKeychain` | `Packages/FleetSecurity` | Shared-keychain-group storage for the push key only (`AfterFirstUnlockThisDeviceOnly`) |
| `RelayKeyID` | `Packages/FleetSecurity` | Generator/validator for the per-gateway `relay_key_id` (32 random bytes, base64url) |
| `FleetSharedServices` | `HermesFleetApp` | Composition helper the app uses as the snapshot writer |
| `Config/SharedGroups.entitlements` | repository | App Group and keychain-access-group entitlements, applied only when the switch is on |

No extension targets are added by this work. They arrive with the push, Live
Activity, and widget lanes.

## Dependency rule

Extension targets may link only `FleetCore`, `FleetSecurity`, and
`FleetClientKit`. `FleetClientKit` imports only Foundation, Security, OSLog,
CryptoKit, FleetCore, and FleetSecurity: no FleetNetworking, FleetUI,
FleetPersistence, SwiftUI, UIKit, or SwiftData. Enforced by
`scripts/extension_boundary_guard.py` (with `scripts/extension_boundary_guard_test.sh`,
run from `scripts/c1_static.sh`), by `FleetClientKit`'s own `KitBoundaryTests`,
and by `ModuleBoundaryTests`.

## Capability switch (default off)

Enabling an App Group or keychain access group on the shipping app needs matching
capabilities on the Apple Developer portal and new provisioning profiles. Until a
maintainer does that, the entitlements must not be applied, or the signed
Release path breaks.

One build setting controls this, `FLEET_SHARED_GROUPS` in `project.yml`, default
`NO` in every configuration:

- `CODE_SIGN_ENTITLEMENTS` resolves to `Config/SharedGroups.entitlements` only when
  the switch is `YES`; otherwise it is empty and no entitlements are applied.
- The built Info.plist carries `FleetSharedGroupsEnabled` from the same setting.
  `FleetSharedConfiguration` reads it at runtime, so code and entitlements always
  agree.

Runtime behavior with the switch off: the shared container falls back to the app's
Application Support directory, and the push key (when a later lane creates it) is
stored in the app's own keychain group with the same accessibility. Nothing asks
the OS for a group. With the switch on, the App Group container is used if the OS
grants it, and falls back to the app container if it does not.

Identifiers: the App Group is the public string `group.com.aiowa.hermesfleet`. The
keychain group is `$(AppIdentifierPrefix)com.aiowa.hermesfleet.shared`, resolved by
Xcode at build time and read back from the built Info.plist; no team identifier is
stored in source. An unresolved prefix never produces a keychain group.

### Maintainer steps to enable

1. On the Apple Developer portal, register the App Group `group.com.aiowa.hermesfleet`.
2. On the app's App ID, enable App Groups (assign that group) and Keychain Sharing
   (group `com.aiowa.hermesfleet.shared`, which Xcode prefixes with the team).
   Repeat for each extension App ID when extension targets are added.
3. Regenerate the provisioning profile(s) for the affected App IDs.
4. Set `FLEET_SHARED_GROUPS: "YES"` in `project.yml` (or pass
   `FLEET_SHARED_GROUPS=YES` to `xcodebuild`), run `xcodegen generate`, and verify
   with `make release-preflight`.
5. A push key created under the fallback lives in the app-private group; after
   the switch flips, re-create it and re-register (the registration flow already
   supports rotation).

Do not commit provisioning profiles, signing identities, or team identifiers.

## What is shared, and how it is protected

- **Push key**: only item allowed in the shared keychain group (closed enum, so a
  gateway secret cannot be stored there by accident). `AfterFirstUnlockThisDeviceOnly`:
  a locked-device NSE can read it after the first unlock following boot; it is
  excluded from backup and device migration and is not synced.
- **Gateway credentials, tokens, TLS pins**: unchanged, app-private,
  `WhenUnlockedThisDeviceOnly`, no access group. Unit tests assert this.
- **`relay_key_id`**: a per-gateway secret shared only with that gateway. Keep it
  in app-private storage, never in the snapshot or the shared group.
- **Transcript cache**: unchanged (`NSFileProtectionComplete`, app-private).
- **Snapshot**: `extension-snapshot.v1.json` in the shared container. Contains only
  an opaque gateway handle, a short label, coarse counts (running, needs attention,
  online), timestamps, `contentHidden`, and the schema version. Never transcript
  text, commands, hostnames, tokens, or session titles. The handle is random and
  app-assigned because a `GatewayID` can embed host and port.
  - Protection class `completeUntilFirstUserAuthentication`: widgets, Live
    Activities, and the NSE must read it while the device is locked (the normal
    state when a push arrives). `complete` would make it unreadable then. The
    content is redacted display data, so readability after first unlock is an
    accepted trade-off. Before the first unlock after a reboot, extensions show
    their generic fallback.
  - App Lock on: the writer sets `contentHidden = true` and replaces names with
    "Gateway N" (`ExtensionSnapshotBuilder`).
  - Bounded: 16 KiB cap, 32 gateways, 40-character labels. Written atomically; the
    reader checks the schema version first and fails closed on newer, older,
    corrupt, or oversized files. The directory is excluded from backup.
- **One-shot client**: https only, no credentials in the URL, bounded time and
  response size, redacted errors, verify-only SPKI pin check (no trust on first
  use). Pins stay app-private, so an extension needs a pin handed to it through
  another channel (`FixedPinStore`); the app can pass its own pin store.

## Validation

```sh
swift test --package-path Packages/FleetSecurity
swift test --package-path Packages/FleetClientKit
bash scripts/extension_boundary_guard_test.sh
make test   # hosted ModuleBoundaryTests and ExtensionKitTests
```
