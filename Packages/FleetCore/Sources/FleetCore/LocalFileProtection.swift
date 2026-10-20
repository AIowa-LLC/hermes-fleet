import Foundation
import OSLog

/// Applies iOS Data Protection and backup exclusion to privacy-bearing local
/// files and directories. Failures from the best-effort path are logged with
/// no URL, contents, or error message; callers choose the right availability
/// policy for their store.
public enum LocalFileProtection {
    public struct Attributes: Sendable, Equatable {
        public let backupExcluded: Bool?
        public let protectionClass: String?
    }

    private static let logger = Logger(
        subsystem: "com.aiowa.hermesfleet",
        category: "LocalFileProtection"
    )

    /// Apply `.complete` Data Protection on iOS and backup exclusion on all
    /// supported platforms. Throws so a caller can fail closed where needed.
    public static func apply(to url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)

        #if os(iOS)
        try (url as NSURL).setResourceValue(FileProtectionType.complete, forKey: .fileProtectionKey)
        #endif
    }

    /// Best-effort path for availability-sensitive stores. The caller can
    /// preserve service availability while tests and read-back checks expose
    /// missing attributes.
    @discardableResult
    public static func applyBestEffort(to url: URL) -> Bool {
        do {
            try apply(to: url)
            return true
        } catch {
            logger.error("Local file protection could not be applied (\(String(describing: type(of: error)), privacy: .private))")
            return false
        }
    }

    /// Read back attributes without treating an unavailable platform value as
    /// proof. iOS device tests can assert the exact class; macOS host tests
    /// still verify backup exclusion and persistence behavior.
    public static func read(from url: URL) -> Attributes {
        let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey, .fileProtectionKey])
        return Attributes(
            backupExcluded: values?.isExcludedFromBackup,
            protectionClass: values?.fileProtection?.rawValue
        )
    }
}
