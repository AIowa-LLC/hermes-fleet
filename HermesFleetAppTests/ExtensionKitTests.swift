import XCTest
import FleetCore
import FleetSecurity
import FleetClientKit
@testable import HermesFleetApp

/// F3 extension kit, app side: the shared-group capability is OFF by default so
/// the existing Release/distribution signing path is unchanged, and the snapshot
/// writer composes correctly over the resolved container.
final class ExtensionKitTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func projectYML() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
    }

    // MARK: default-off release safety

    func testSharedGroupsSwitchIsOffByDefaultAndGatesTheEntitlementsFile() throws {
        let yml = try projectYML()
        XCTAssertTrue(yml.contains("FLEET_SHARED_GROUPS: \"NO\""), "the switch must default to NO")
        XCTAssertTrue(yml.contains("FLEET_ENTITLEMENTS_NO: \"\""), "switch off = no entitlements file")
        XCTAssertTrue(yml.contains("CODE_SIGN_ENTITLEMENTS: \"$(FLEET_ENTITLEMENTS_$(FLEET_SHARED_GROUPS))\""))
        // No other path may apply entitlements unconditionally.
        let applied = yml.components(separatedBy: "CODE_SIGN_ENTITLEMENTS").count - 1
        XCTAssertEqual(applied, 1, "CODE_SIGN_ENTITLEMENTS is set in exactly one, switch-gated place")
        XCTAssertFalse(yml.contains("entitlements:\n"), "no unconditional XcodeGen entitlements: block")
    }

    func testEntitlementsFileHoldsOnlyGroupVariablesAndNoIdentifiers() throws {
        let url = repoRoot.appendingPathComponent("Config/SharedGroups.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(Set(plist.keys), ["com.apple.security.application-groups", "keychain-access-groups"])
        XCTAssertEqual(plist["com.apple.security.application-groups"] as? [String], ["$(FLEET_APP_GROUP_ID)"])
        XCTAssertEqual(plist["keychain-access-groups"] as? [String], ["$(FLEET_KEYCHAIN_GROUP)"])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("aps-environment"), "push entitlement belongs to the push lane")
        XCTAssertTrue(try projectYML().contains("FLEET_KEYCHAIN_GROUP: \"$(AppIdentifierPrefix)"),
                      "keychain group uses the build-variable prefix, never a literal team id")
    }

    func testBuiltAppInfoPlistAgreesWithTheSwitch() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        let raw = try XCTUnwrap(info[FleetSharedConfiguration.enabledInfoKey] as? String)
        XCTAssertTrue(["YES", "NO"].contains(raw))
        let configuration = FleetSharedConfiguration(bundle: .main)
        XCTAssertEqual(configuration.sharedGroupsEnabled, raw == "YES")
        XCTAssertEqual(info[FleetSharedConfiguration.appGroupInfoKey] as? String,
                       FleetSharedConfiguration.proposedAppGroupIdentifier)
    }

    func testDefaultBuildFallsBackToTheAppContainerAndAppPrivateKeychain() throws {
        // Only meaningful for the default (switch off) build, which CI uses.
        try XCTSkipIf(FleetSharedConfiguration(bundle: .main).sharedGroupsEnabled,
                      "built with FLEET_SHARED_GROUPS=YES")
        let services = FleetSharedServices.live()
        XCTAssertFalse(services.configuration.sharedGroupsEnabled)
        XCTAssertEqual(services.container.backing, .appContainerFallback)
        XCTAssertNil(services.configuration.keychainAccessGroup)
        XCTAssertNil(services.pushKeychain.accessGroup)
    }

    // MARK: composition

    func testEnabledCapabilityResolvesAppGroupAndKeychainGroup() {
        struct GrantingLocator: AppGroupContainerLocating {
            func containerURL(forAppGroup groupIdentifier: String) -> URL? {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("F3Group-\(groupIdentifier)", isDirectory: true)
            }
        }
        let configuration = FleetSharedConfiguration(infoDictionary: [
            FleetSharedConfiguration.enabledInfoKey: "YES",
            FleetSharedConfiguration.keychainGroupInfoKey: "SYNTHETIC1.com.aiowa.hermesfleet.shared",
        ])
        let services = FleetSharedServices.make(configuration: configuration, locator: GrantingLocator())
        XCTAssertEqual(services.container.backing, .appGroup)
        XCTAssertEqual(services.pushKeychain.accessGroup, "SYNTHETIC1.com.aiowa.hermesfleet.shared")
    }

    func testPublishSnapshotWritesRedactedFilesProtectedAndExcludedFromBackup() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("F3Snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let services = FleetSharedServices.make(
            configuration: .disabled, fallbackBaseURL: base)
        let handle = try XCTUnwrap(OpaqueGatewayHandle.generate())
        let input = ExtensionSnapshotBuilder.GatewayInput(
            handle: handle, displayName: "Synthetic Box", runningCount: 2, needsAttentionCount: 1, onlineCount: 3)

        let open = try services.publishSnapshot(gateways: [input], appLockEnabled: false)
        XCTAssertEqual(try services.snapshotStore.read(), open)
        XCTAssertEqual(open.gateways.first?.displayLabel, "Synthetic Box")

        let locked = try services.publishSnapshot(gateways: [input], appLockEnabled: true)
        XCTAssertTrue(locked.contentHidden)
        let raw = String(decoding: try Data(contentsOf: services.snapshotStore.fileURL), as: UTF8.self)
        XCTAssertFalse(raw.contains("Synthetic Box"), "App Lock on: names are not written")
        XCTAssertTrue(raw.contains("Gateway 1"))

        // Protection class + backup exclusion (the simulator reports its default
        // class, CompleteUntilFirstUserAuthentication, so the class is asserted
        // as present and equal to the deliberately chosen one; the exact class on
        // device comes from the write option and is covered by the package tests).
        let attributes = try FileManager.default.attributesOfItem(atPath: services.snapshotStore.fileURL.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType,
                       ExtensionSnapshotStore.fileProtection)
        let values = try services.container.directoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testPushKeyStoresInThePrivateFallbackKeychainWhenGroupsAreOff() throws {
        // Real simulator keychain round trip for the fallback path.
        let store = FleetSharedKeychain(accessGroup: nil)
        let key = Data((0..<32).map { UInt8($0 &* 3) })
        defer { try? store.delete(item: .pushPrivateKey) }
        try store.save(key, item: .pushPrivateKey)
        XCTAssertEqual(try store.load(item: .pushPrivateKey), key)
        try store.delete(item: .pushPrivateKey)
        XCTAssertNil(try store.load(item: .pushPrivateKey))
    }
}
