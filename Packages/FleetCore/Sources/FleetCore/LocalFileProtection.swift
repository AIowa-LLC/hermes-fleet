import Foundation

/// On-device protection for privacy-bearing local files (P0.3c).
///
/// One policy for every store that can hold transcript text, room events,
/// member names, drafts or staged artifacts:
///
/// - **Protection class: `NSFileProtectionComplete`.** Readable only while the
///   device is unlocked. Chosen deliberately over
///   `CompleteUntilFirstUserAuthentication`: nothing in the app reads these
///   files while locked today, so the stricter class costs nothing. Background
///   or extension reads (#100) may need a looser class for a *separate*,
///   narrower snapshot store; that is a later decision and this policy is not
///   weakened in anticipation of it.
/// - **Backup exclusion** (`isExcludedFromBackup`): none of these files ride
///   along in device or iCloud backups.
/// - **Directory inheritance.** Files created later (a new SQLite `-wal`, an
///   atomic-write temp file) cannot be protected by name before they exist, so
///   their containing directory is protected too and new files inherit its
///   class. Callers still re-apply after the first write and read the
///   attributes back (`read`) because inheritance is a platform behavior, not
///   something this code can assert.
///
/// Protection classes are an iOS data-protection feature. On the macOS host
/// (package tests) the class is neither applied nor reported; backup exclusion
/// works everywhere.
///
/// Failures carry only an operation label and a Swift type name
/// (`Failure.diagnosticsDetail`), so they are safe for the redacted
/// diagnostics ring: no path, file name or error message.
public enum LocalFileProtection {
    /// The attributes read back from disk.
    public struct Attributes: Sendable, Equatable {
        /// nil when the URL does not exist / the value is unreadable.
        public let backupExcluded: Bool?
        /// `FileProtectionType.rawValue`; nil off iOS or when unreadable.
        public let fileProtection: String?

        public init(backupExcluded: Bool?, fileProtection: String?) {
            self.backupExcluded = backupExcluded
            self.fileProtection = fileProtection
        }

        /// True when backup exclusion is set and the file does not report the
        /// explicit "no protection" class. A nil class is not evidence of
        /// missing protection: directories and the simulator report none.
        public var isProtected: Bool {
            backupExcluded == true && fileProtection != FileProtectionType.none.rawValue
        }
    }

    /// A redacted (type-only) record of one failed protection operation.
    public struct Failure: Error, Sendable, Equatable {
        /// Closed label for the file role, e.g. `"directory"`, `"store"`,
        /// `"wal"`, `"shm"`, `"drafts"`. Never a path.
        public let role: String
        /// Swift type name of the underlying error; never its message.
        public let errorType: String

        public init(role: String, error: Error) {
            self.role = role
            self.errorType = String(describing: type(of: error))
        }

        public var diagnosticsDetail: String {
            "file protection could not be applied (\(role), \(errorType))"
        }
    }

    // MARK: Apply

    /// Backup-exclude `url` and set `NSFileProtectionComplete` on it (file or
    /// directory). Throws the first failure.
    public static func apply(to url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try (url as NSURL).setResourceValue(FileProtectionType.complete, forKey: .fileProtectionKey)
        #endif
    }

    /// Create `directory` if needed and apply the policy to it, so files
    /// created inside later inherit the protection class and backup exclusion.
    public static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try apply(to: directory)
    }

    /// Write options that set the protection class on the file the atomic
    /// write creates (no-op off iOS).
    public static var writingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }

    /// Atomic, protected write. An atomic write replaces the inode, which
    /// drops the backup-exclusion attribute, so exclusion is re-asserted after
    /// every write. A failed write throws; a failed post-write attribute
    /// application throws `Failure` *after* the bytes are safely on disk, so a
    /// caller that prefers availability can treat it as non-fatal.
    public static func write(_ data: Data, to url: URL, role: String = "file") throws {
        try data.write(to: url, options: writingOptions)
        do {
            try apply(to: url)
        } catch {
            throw Failure(role: role, error: error)
        }
    }

    /// Best-effort application to `urls` that exist, collecting failures
    /// instead of throwing. Missing files are skipped (not failures).
    @discardableResult
    public static func applyBestEffort(to urls: [(role: String, url: URL)]) -> [Failure] {
        var failures: [Failure] = []
        for entry in urls where FileManager.default.fileExists(atPath: entry.url.path) {
            do { try apply(to: entry.url) } catch { failures.append(Failure(role: entry.role, error: error)) }
        }
        return failures
    }

    // MARK: Read back

    /// Read the attributes back for verification (tests, diagnostics).
    public static func read(from url: URL) -> Attributes {
        // `URL` caches resource values per instance; a read-back must see the
        // disk, not a value cached before a rewrite or attribute change.
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey, .fileProtectionKey])
        var protection = values?.fileProtection?.rawValue
        #if os(iOS)
        // Directories do not report the class through resource values; the
        // file-manager attribute is the effective class for both.
        if protection == nil,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let type = attributes[.protectionKey] as? FileProtectionType {
            protection = type.rawValue
        }
        #endif
        return Attributes(
            backupExcluded: values?.isExcludedFromBackup,
            fileProtection: protection)
    }

    /// The raw value `apply` sets on iOS (`FileProtectionType.complete`).
    public static let completeProtectionRawValue = FileProtectionType.complete.rawValue
}
