import Foundation

/// Whether this build shares an App Group container and a keychain access group
/// with extensions — the runtime half of the F3 capability switch.
///
/// Shipping signed builds must keep working before the maintainer has registered
/// the App Group / keychain group capabilities and regenerated provisioning
/// profiles. So the capability is OFF by default and is decided by one build
/// setting (`FLEET_SHARED_GROUPS`, see `project.yml` and
/// `docs/extension-kit.md`) that flips two things together:
/// 1. `CODE_SIGN_ENTITLEMENTS` (the entitlements file is only applied when
///    the switch is `YES`), and
/// 2. the `FleetSharedGroupsEnabled` Info.plist key this type reads.
///
/// With the switch off, nothing here ever asks the OS for a group: the shared
/// container falls back to the app container and the push key stays in the app's
/// own keychain group. Identifiers are read from the built Info.plist so that no
/// team identifier is ever committed to source (the keychain group arrives as
/// `$(AppIdentifierPrefix)…`, resolved by Xcode at build time).
public struct FleetSharedConfiguration: Sendable, Equatable {
    public static let enabledInfoKey = "FleetSharedGroupsEnabled"
    public static let appGroupInfoKey = "FleetAppGroupIdentifier"
    public static let keychainGroupInfoKey = "FleetSharedKeychainAccessGroup"

    /// The proposed App Group identifier (a public string; registering it on the
    /// Apple Developer portal is a maintainer-only step).
    public static let proposedAppGroupIdentifier = "group.com.aiowa.hermesfleet"
    /// The keychain access group identifier WITHOUT its team prefix. The full
    /// group is `<AppIdentifierPrefix><suffix>` and is resolved at build time.
    public static let keychainAccessGroupSuffix = "com.aiowa.hermesfleet.shared"

    /// True only when the build was produced with the shared-group switch on.
    public let sharedGroupsEnabled: Bool
    /// The App Group identifier (meaningful only when `sharedGroupsEnabled`).
    public let appGroupIdentifier: String
    /// The fully resolved keychain access group, or nil when the switch is off
    /// or the team prefix did not resolve (fail closed — never guess a prefix).
    public let keychainAccessGroup: String?

    /// Everything off: app-container fallback, app-private keychain.
    public static let disabled = FleetSharedConfiguration(
        sharedGroupsEnabled: false,
        appGroupIdentifier: proposedAppGroupIdentifier,
        keychainAccessGroup: nil
    )

    public init(sharedGroupsEnabled: Bool, appGroupIdentifier: String, keychainAccessGroup: String?) {
        self.sharedGroupsEnabled = sharedGroupsEnabled
        self.appGroupIdentifier = appGroupIdentifier
        self.keychainAccessGroup = keychainAccessGroup
    }

    /// Parse the built Info.plist values. Missing or unrecognized values mean
    /// "disabled".
    public init(infoDictionary: [String: Any]?) {
        let info = infoDictionary ?? [:]
        let enabled = Self.parseFlag(info[Self.enabledInfoKey])
        let rawGroup = (info[Self.appGroupInfoKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appGroup = Self.isValidAppGroup(rawGroup) ? rawGroup! : Self.proposedAppGroupIdentifier
        let rawKeychain = (info[Self.keychainGroupInfoKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            sharedGroupsEnabled: enabled,
            appGroupIdentifier: appGroup,
            keychainAccessGroup: enabled && Self.isResolvedKeychainGroup(rawKeychain) ? rawKeychain : nil
        )
    }

    public init(bundle: Bundle = .main) {
        self.init(infoDictionary: bundle.infoDictionary)
    }

    /// The App Group to request from the OS, or nil when sharing is off.
    public var requestedAppGroupIdentifier: String? {
        sharedGroupsEnabled ? appGroupIdentifier : nil
    }

    private static func parseFlag(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "yes", "true", "1": return true
            default: return false
            }
        }
        return false
    }

    private static func isValidAppGroup(_ value: String?) -> Bool {
        guard let value, value.hasPrefix("group."), value.count > "group.".count else { return false }
        return !value.contains(" ")
    }

    /// A keychain group is resolved only when a non-empty team prefix precedes
    /// the known suffix (`<prefix>.<suffix>`). An unresolved `$(AppIdentifierPrefix)`
    /// substitutes to nothing and leaves the bare suffix, which must not be used.
    private static func isResolvedKeychainGroup(_ value: String?) -> Bool {
        guard let value, !value.contains("$(") else { return false }
        let marker = "." + keychainAccessGroupSuffix
        guard value.hasSuffix(marker) else { return false }
        return value.count > marker.count
    }
}
