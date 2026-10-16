import XCTest
@testable import FleetClientKit

private struct StubLocator: AppGroupContainerLocating {
    var url: URL?
    var requested: @Sendable (String) -> Void = { _ in }

    func containerURL(forAppGroup groupIdentifier: String) -> URL? {
        requested(groupIdentifier)
        return url
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var groups: [String] = []
    func record(_ group: String) { lock.lock(); groups.append(group); lock.unlock() }
    var requested: [String] { lock.lock(); defer { lock.unlock() }; return groups }
}

final class FleetSharedConfigurationTests: XCTestCase {
    private let teamPrefixedGroup = "SYNTHETIC1.com.aiowa.hermesfleet.shared"

    // MARK: configuration parsing

    func testMissingOrDisabledFlagMeansDisabled() {
        XCTAssertFalse(FleetSharedConfiguration(infoDictionary: nil).sharedGroupsEnabled)
        XCTAssertFalse(FleetSharedConfiguration(infoDictionary: [:]).sharedGroupsEnabled)
        for value in ["NO", "no", "", "0", "false", "maybe"] {
            let configuration = FleetSharedConfiguration(infoDictionary: [
                FleetSharedConfiguration.enabledInfoKey: value,
                FleetSharedConfiguration.keychainGroupInfoKey: teamPrefixedGroup,
            ])
            XCTAssertFalse(configuration.sharedGroupsEnabled, value)
            XCTAssertNil(configuration.keychainAccessGroup, "no keychain group when the switch is off")
            XCTAssertNil(configuration.requestedAppGroupIdentifier)
        }
    }

    func testEnabledFlagIsParsedFromStringAndBool() {
        for value: Any in ["YES", "yes", "true", "1", true] {
            let configuration = FleetSharedConfiguration(infoDictionary: [
                FleetSharedConfiguration.enabledInfoKey: value,
                FleetSharedConfiguration.keychainGroupInfoKey: teamPrefixedGroup,
            ])
            XCTAssertTrue(configuration.sharedGroupsEnabled, "\(value)")
            XCTAssertEqual(configuration.keychainAccessGroup, teamPrefixedGroup)
            XCTAssertEqual(configuration.requestedAppGroupIdentifier,
                           FleetSharedConfiguration.proposedAppGroupIdentifier)
        }
    }

    func testUnresolvedTeamPrefixNeverProducesAKeychainGroup() {
        let unresolved = [
            FleetSharedConfiguration.keychainAccessGroupSuffix,            // empty prefix substitution
            "." + FleetSharedConfiguration.keychainAccessGroupSuffix,
            "$(AppIdentifierPrefix)" + FleetSharedConfiguration.keychainAccessGroupSuffix,
            "",
            "SYNTHETIC1.com.other.group",
        ]
        for value in unresolved {
            let configuration = FleetSharedConfiguration(infoDictionary: [
                FleetSharedConfiguration.enabledInfoKey: "YES",
                FleetSharedConfiguration.keychainGroupInfoKey: value,
            ])
            XCTAssertNil(configuration.keychainAccessGroup, "'\(value)' must not be used")
        }
    }

    func testCustomAppGroupIsHonouredOnlyWhenWellFormed() {
        var configuration = FleetSharedConfiguration(infoDictionary: [
            FleetSharedConfiguration.enabledInfoKey: "YES",
            FleetSharedConfiguration.appGroupInfoKey: "group.example.synthetic",
        ])
        XCTAssertEqual(configuration.appGroupIdentifier, "group.example.synthetic")
        configuration = FleetSharedConfiguration(infoDictionary: [
            FleetSharedConfiguration.enabledInfoKey: "YES",
            FleetSharedConfiguration.appGroupInfoKey: "not-a-group",
        ])
        XCTAssertEqual(configuration.appGroupIdentifier, FleetSharedConfiguration.proposedAppGroupIdentifier)
    }

    func testDisabledConstant() {
        XCTAssertFalse(FleetSharedConfiguration.disabled.sharedGroupsEnabled)
        XCTAssertNil(FleetSharedConfiguration.disabled.keychainAccessGroup)
        XCTAssertNil(FleetSharedConfiguration.disabled.requestedAppGroupIdentifier)
    }

    // MARK: container resolution (runtime capability check)

    private var tempBase: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FleetSharedTests", isDirectory: true)
    }

    func testDisabledConfigurationNeverAsksTheOSForAGroup() {
        let recorder = RequestRecorder()
        let locator = StubLocator(url: URL(fileURLWithPath: "/synthetic/group"), requested: { recorder.record($0) })
        let container = FleetSharedContainer.resolve(
            configuration: .disabled, locator: locator, fallbackBaseURL: tempBase)
        XCTAssertEqual(container.backing, .appContainerFallback)
        XCTAssertTrue(recorder.requested.isEmpty, "capability off: the OS is never asked for the App Group")
        XCTAssertEqual(container.directoryURL, tempBase.appendingPathComponent("FleetShared", isDirectory: true))
    }

    func testEnabledConfigurationUsesTheAppGroupContainerWhenGranted() {
        let configuration = FleetSharedConfiguration(infoDictionary: [
            FleetSharedConfiguration.enabledInfoKey: "YES",
        ])
        let recorder = RequestRecorder()
        let groupURL = URL(fileURLWithPath: "/synthetic/group", isDirectory: true)
        let container = FleetSharedContainer.resolve(
            configuration: configuration,
            locator: StubLocator(url: groupURL, requested: { recorder.record($0) }),
            fallbackBaseURL: tempBase)
        XCTAssertEqual(container.backing, .appGroup)
        XCTAssertEqual(recorder.requested, [FleetSharedConfiguration.proposedAppGroupIdentifier])
        XCTAssertEqual(container.directoryURL, groupURL.appendingPathComponent("FleetShared", isDirectory: true))
    }

    func testEnabledConfigurationFallsBackWhenTheOSDeniesTheGroup() {
        let configuration = FleetSharedConfiguration(infoDictionary: [
            FleetSharedConfiguration.enabledInfoKey: "YES",
        ])
        let container = FleetSharedContainer.resolve(
            configuration: configuration, locator: StubLocator(url: nil), fallbackBaseURL: tempBase)
        XCTAssertEqual(container.backing, .appContainerFallback,
                       "an entitlement/profile mismatch degrades to the app container, never crashes")
    }

    func testTypedLocationsAreFixedFileNames() {
        let container = FleetSharedContainer(backing: .appContainerFallback, directoryURL: tempBase)
        XCTAssertEqual(FleetSharedContainer.Location.allCases, [.extensionSnapshot])
        XCTAssertEqual(container.url(for: .extensionSnapshot).lastPathComponent, "extension-snapshot.v1.json")
    }
}
