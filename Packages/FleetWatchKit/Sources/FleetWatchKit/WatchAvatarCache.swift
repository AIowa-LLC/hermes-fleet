import Foundation

/// Bot avatar thumbnails on the Watch, keyed by content digest. Bytes are
/// verified against their digest on write AND read, so a corrupted or swapped
/// file is never shown as some other bot's face. Bounded by pruning to the
/// digests the latest snapshot still advertises (no file dates are read, so no
/// required-reason API is involved). It only ever holds images.
public struct WatchAvatarCache: Sendable {
    public let directory: URL?

    /// `directory == nil` keeps nothing on disk (in-memory store only).
    public init(directory: URL?) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FleetWatchDev/avatars", isDirectory: true)
    }

    private static func isDigest(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy(\.isHexDigit)
    }

    private func url(for digest: String) -> URL? {
        // Digests are hex; anything else never becomes a path component.
        guard let directory, Self.isDigest(digest) else { return nil }
        return directory.appendingPathComponent(digest)
    }

    public func load(_ digest: String) -> Data? {
        guard let url = url(for: digest), let data = try? Data(contentsOf: url) else { return nil }
        guard WatchAvatarImage(digest: digest, data: data).isValid else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return data
    }

    @discardableResult
    public func store(_ image: WatchAvatarImage) -> Bool {
        guard image.isValid, let data = image.data, let url = url(for: image.digest), let directory else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    /// Removes every cached thumbnail whose digest is not in `keep`. Files
    /// that aren't digest-named are left alone.
    public func prune(keeping keep: Set<String>) {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where Self.isDigest(name) && !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
