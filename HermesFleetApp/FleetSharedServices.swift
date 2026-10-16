import Foundation
import FleetClientKit
import FleetSecurity

/// F3 composition root for state shared with app extensions.
///
/// Resolves, once, from the built Info.plist (`FleetSharedConfiguration`):
/// - where the extension snapshot lives (App Group container when the build
///   enabled shared groups AND the OS grants the group; otherwise the app's own
///   Application Support directory), and
/// - which keychain access group, if any, holds the push key.
///
/// With `FLEET_SHARED_GROUPS=NO` (the default for every configuration) this is
/// inert: no App Group or shared keychain group is requested, which keeps the
/// existing signing/provisioning path valid. Gateway credentials, tokens and
/// TLS pins never use these services; they keep their app-private stores.
///
/// The snapshot WRITER is the app; extensions only read. Later lanes (push,
/// widgets, Live Activity) call `publishSnapshot` when fleet state changes.
struct FleetSharedServices: Sendable {
    let configuration: FleetSharedConfiguration
    let container: FleetSharedContainer
    let snapshotStore: ExtensionSnapshotStore
    let pushKeychain: FleetSharedKeychain

    static func live(
        bundle: Bundle = .main,
        locator: any AppGroupContainerLocating = LiveAppGroupContainerLocator()
    ) -> FleetSharedServices {
        make(configuration: FleetSharedConfiguration(bundle: bundle), locator: locator)
    }

    static func make(
        configuration: FleetSharedConfiguration,
        locator: any AppGroupContainerLocating = LiveAppGroupContainerLocator(),
        fallbackBaseURL: URL? = nil
    ) -> FleetSharedServices {
        let container = FleetSharedContainer.resolve(
            configuration: configuration, locator: locator, fallbackBaseURL: fallbackBaseURL)
        return FleetSharedServices(
            configuration: configuration,
            container: container,
            snapshotStore: ExtensionSnapshotStore(container: container),
            pushKeychain: FleetSharedKeychain(accessGroup: configuration.keychainAccessGroup)
        )
    }

    /// Build a redacted snapshot (names hidden when App Lock is on) and write it.
    @discardableResult
    func publishSnapshot(
        gateways: [ExtensionSnapshotBuilder.GatewayInput],
        appLockEnabled: Bool,
        now: Date = Date()
    ) throws -> ExtensionSnapshot {
        let snapshot = ExtensionSnapshotBuilder.make(
            gateways: gateways, appLockEnabled: appLockEnabled, now: now)
        try snapshotStore.write(snapshot)
        return snapshot
    }
}
