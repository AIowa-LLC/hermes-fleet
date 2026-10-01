import Foundation

/// Resolves an App Group container URL. A seam so the capability fallback is
/// testable without an entitled binary.
public protocol AppGroupContainerLocating: Sendable {
    /// The container for `groupIdentifier`, or nil when this process is not
    /// entitled to it (or the group does not exist).
    func containerURL(forAppGroup groupIdentifier: String) -> URL?
}

/// Production locator backed by `FileManager`.
public struct LiveAppGroupContainerLocator: AppGroupContainerLocating {
    public init() {}

    public func containerURL(forAppGroup groupIdentifier: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }
}

/// The shared on-disk location for state the app shares with its extensions,
/// with typed file locations.
///
/// Runtime capability check (F3): when the build enabled shared groups AND the OS
/// grants the App Group container, files live in the App Group container so
/// extensions can read them. Otherwise — the default for every build until the
/// maintainer enables the capability — files live in the app's own Application
/// Support directory. Callers never need to care which: they ask for a typed
/// location and use the URL. Only non-sensitive, rebuildable data belongs here
/// (see `ExtensionSnapshotStore`); secrets never do.
public struct FleetSharedContainer: Sendable, Equatable {
    public enum Backing: Sendable, Equatable {
        /// The real App Group container (extensions can read it).
        case appGroup
        /// The app's own Application Support directory (no extensions can read
        /// it; the safe default while the capability is off).
        case appContainerFallback
    }

    /// The typed files the shared container may hold. Adding a case is a
    /// data-classification decision: only non-sensitive display data.
    public enum Location: String, Sendable, CaseIterable {
        case extensionSnapshot = "extension-snapshot.v1.json"
    }

    /// Directory name used under the container root.
    public static let directoryName = "FleetShared"

    public let backing: Backing
    /// The directory that holds every shared file (not yet created).
    public let directoryURL: URL

    public init(backing: Backing, directoryURL: URL) {
        self.backing = backing
        self.directoryURL = directoryURL
    }

    public func url(for location: Location) -> URL {
        directoryURL.appendingPathComponent(location.rawValue, isDirectory: false)
    }

    /// Resolve the container for `configuration`.
    ///
    /// - Parameters:
    ///   - locator: the App Group locator (injectable for tests).
    ///   - fallbackBaseURL: base directory for the app-container fallback
    ///     (defaults to Application Support; injectable for tests).
    public static func resolve(
        configuration: FleetSharedConfiguration,
        locator: any AppGroupContainerLocating = LiveAppGroupContainerLocator(),
        fallbackBaseURL: URL? = nil
    ) -> FleetSharedContainer {
        if let group = configuration.requestedAppGroupIdentifier,
           let groupURL = locator.containerURL(forAppGroup: group) {
            return FleetSharedContainer(
                backing: .appGroup,
                directoryURL: groupURL.appendingPathComponent(directoryName, isDirectory: true)
            )
        }
        let base = fallbackBaseURL ?? defaultFallbackBaseURL()
        return FleetSharedContainer(
            backing: .appContainerFallback,
            directoryURL: base.appendingPathComponent(directoryName, isDirectory: true)
        )
    }

    /// Create the directory if needed and exclude it from backup (everything in
    /// it is derived and rebuildable from app state).
    public func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
        var url = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private static func defaultFallbackBaseURL() -> URL {
        (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
    }
}
