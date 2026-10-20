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

        public init(backupExcluded: Bool?, protectionClass: String?) {
            self.backupExcluded = backupExcluded
            self.protectionClass = protectionClass
        }

        /// nil means the platform did not report a class; it is not evidence
        /// of `.none`. Physical-device acceptance checks the exact class.
        public var isProtected: Bool {
            guard backupExcluded == true else { return false }
            #if os(iOS)
            return protectionClass != FileProtectionType.none.rawValue
            #else
            return true
            #endif
        }
    }

    /// Safe-to-report detail for a failed attribute operation. Roles are
    /// caller-supplied labels, never paths; the underlying message is omitted.
    public struct Failure: Error, Sendable, Equatable {
        public let role: String
        public let errorType: String

        public init(role: String, error: Error) {
            self.role = role
            self.errorType = String(describing: type(of: error))
        }

        public var diagnosticsDetail: String {
            "local file protection could not be applied (\(role), \(errorType))"
        }
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
        applyBestEffortReportingFailure(to: url, role: "local-file") == nil
    }

    /// Apply protection and return a redacted record instead of throwing.
    @discardableResult
    public static func applyBestEffortReportingFailure(to url: URL, role: String) -> Failure? {
        do {
            try apply(to: url)
            return nil
        } catch {
            let failure = Failure(role: role, error: error)
            logger.error("\(failure.diagnosticsDetail, privacy: .private)")
            return failure
        }
    }

    /// Best-effort application to existing files, preserving each closed role
    /// so callers can add failures to the in-app diagnostics ring.
    public static func applyBestEffort(to entries: [(role: String, url: URL)]) -> [Failure] {
        entries.compactMap { entry in
            guard FileManager.default.fileExists(atPath: entry.url.path) else { return nil }
            return applyBestEffortReportingFailure(to: entry.url, role: entry.role)
        }
    }

    /// Read back attributes without treating an unavailable platform value as
    /// proof. iOS device tests can assert the exact class; macOS host tests
    /// still verify backup exclusion and persistence behavior.
    public static func read(from url: URL) -> Attributes {
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values = try? freshURL.resourceValues(forKeys: [.isExcludedFromBackupKey, .fileProtectionKey])
        var protectionClass = values?.fileProtection?.rawValue
        #if os(iOS)
        // URL resource values do not expose the protection class for every
        // directory. Ask Foundation's file attributes as a read-back fallback.
        if protectionClass == nil,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let type = attributes[.protectionKey] as? FileProtectionType {
            protectionClass = type.rawValue
        }
        #endif
        return Attributes(
            backupExcluded: values?.isExcludedFromBackup,
            protectionClass: protectionClass
        )
    }
}
