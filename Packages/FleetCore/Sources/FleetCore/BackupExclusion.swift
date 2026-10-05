import Foundation

/// Keeps privacy-bearing Application Support files out of device and iCloud
/// backups. Application Support is backed up by default, so every store that
/// persists transcripts, drafts, rooms or artifact metadata must opt out.
///
/// An atomic write replaces the file (and its resource values), so callers
/// re-apply this after EVERY write, and once on load to cover files written
/// before the exclusion existed.
public enum BackupExclusion {
    /// Best-effort: a failure to set the flag must never lose or block the
    /// user's data, so it is swallowed (the next write retries).
    public static func apply(to url: URL) {
        var url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    public static func isExcluded(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }
}
