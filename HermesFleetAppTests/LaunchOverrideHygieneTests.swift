import XCTest
import Security
import FleetSecurity
import FleetUI
import FleetPersistence
@testable import HermesFleetApp

/// P0.3d — launch-environment override hygiene.
///
/// `FleetServiceGraph.lockMode` is the pure mode-selection function behind
/// `makeLockController`. Hosted tests run in DEBUG, so the Release behaviour is
/// covered two ways: `overridesEnabled: false` is exactly what a Release build
/// passes (the `HERMES_FLEET_APP_LOCK` read is compiled out under `#if DEBUG`),
/// and the `#if !DEBUG` test below asserts the compiled-in constant when this
/// bundle is ever built in Release. `scripts/security_hygiene_guard.py` fails
/// CI if any lock override read appears outside a DEBUG block.
@MainActor
final class LaunchOverrideHygieneTests: XCTestCase {

    func testReleaseConfigurationIgnoresDisableOverride() {
        for value in ["off", "disabled", "", "enabled", "on", "follow", "garbage"] {
            XCTAssertEqual(
                FleetServiceGraph.lockMode(
                    environment: ["HERMES_FLEET_APP_LOCK": value],
                    overridesEnabled: false),
                .followSetting,
                "override '\(value)' must not change the mode when overrides are disabled")
        }
        XCTAssertEqual(
            FleetServiceGraph.lockMode(environment: [:], overridesEnabled: false),
            .followSetting)
    }

    func testDebugConfigurationStillHonorsOverrides() {
        #if DEBUG
        XCTAssertTrue(FleetServiceGraph.lockOverridesEnabled)
        func mode(_ value: String?) -> AppLockController.Mode {
            FleetServiceGraph.lockMode(
                environment: value.map { ["HERMES_FLEET_APP_LOCK": $0] } ?? [:],
                overridesEnabled: true)
        }
        XCTAssertEqual(mode("off"), .disabled)
        XCTAssertEqual(mode("disabled"), .disabled)
        XCTAssertEqual(mode("enabled"), .enabled)
        XCTAssertEqual(mode("on"), .enabled)
        XCTAssertEqual(mode("follow"), .followSetting)
        // Unset in DEBUG keeps the deterministic UI suites unlocked.
        XCTAssertEqual(mode(nil), .disabled)
        #endif
    }

    func testClearingLocalCachePreservesUpgradeEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(FleetServiceGraph.hasPriorInstallEvidence(cacheDirectory: directory))
        let cache = try SwiftDataCacheStore.makeFileBacked(storeURL: directory.appendingPathComponent("cache.store"))
        XCTAssertTrue(FleetServiceGraph.hasPriorInstallEvidence(cacheDirectory: directory))
        try await cache.clearCachedData()
        XCTAssertTrue(FleetServiceGraph.hasPriorInstallEvidence(cacheDirectory: directory),
                      "clearing cached rows cannot make an upgrade look like a reinstall")
    }

    func testLiveKeychainInstallDecisionsPreserveUpgradeAndPurgeReinstall() throws {
        // Isolated service and defaults: never touches a maintainer's credentials.
        let namespace = "com.aiowa.hermesfleet.tests.install." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: namespace))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace,
            kSecAttrAccount as String: "synthetic-account",
        ]
        defer {
            SecItemDelete(query as CFDictionary)
            preferences.removePersistentDomain(forName: namespace)
        }
        var item = query
        item[kSecValueData as String] = Data("synthetic-value".utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        let hygiene = KeychainInstallHygiene(defaults: preferences, services: [namespace])
        XCTAssertEqual(hygiene.runIfNeeded(hasPriorInstallEvidence: true), .adoptedExistingInstall)
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecSuccess,
                       "upgrading preserves real Keychain items")
        XCTAssertEqual(hygiene.runIfNeeded(hasPriorInstallEvidence: false), .skippedMarkerPresent)
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecSuccess)
        // Losing the sandbox marker models reinstall while the Keychain survives.
        preferences.removePersistentDomain(forName: namespace)
        XCTAssertEqual(hygiene.runIfNeeded(hasPriorInstallEvidence: false), .purged(count: 1))
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
        XCTAssertEqual(hygiene.runIfNeeded(hasPriorInstallEvidence: false), .skippedMarkerPresent)
    }

    #if !DEBUG
    func testReleaseBuildCompilesOverridesOut() {
        XCTAssertFalse(FleetServiceGraph.lockOverridesEnabled)
        XCTAssertEqual(
            FleetServiceGraph.lockMode(
                environment: ["HERMES_FLEET_APP_LOCK": "off"],
                overridesEnabled: FleetServiceGraph.lockOverridesEnabled),
            .followSetting)
    }
    #endif
}
