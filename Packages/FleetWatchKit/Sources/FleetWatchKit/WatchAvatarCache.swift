import Foundation

/// Bot avatar thumbnails on the Watch, keyed by content digest. Bytes are
/// verified against their digest on write AND read, so a corrupted or swapped
/// file is never shown as some other bot's face. Bounded: the oldest files are
/// dropped past `capacity`. It only ever holds images; nothing here is a secret.
public struct WatchAvatarCache: Sendable {
    public let directory: URL?
    public let capacity: Int

    /// `directory == nil` keeps nothing on disk (in-memory store only).
    public init(directory: URL?, capacity: Int = 48) {
        self.directory = directory
        self.capacity = capacity
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FleetWatchDev/avatars", isDirectory: true)
    }

    private func url(for digest: String) -> URL? {
        // Digests are hex; anything else never becomes a path component.
        guard let directory, digest.count == 64, digest.allSatisfy(\.isHexDigit) else { return nil }
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
        } catch {
            return false
        }
        evictBeyondCapacity()
        return true
    }

    private func evictBeyondCapacity() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > capacity else { return }
        let dated = files.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (url, date ?? .distantPast)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(files.count - capacity) { try? FileManager.default.removeItem(at: url) }
    }
}
