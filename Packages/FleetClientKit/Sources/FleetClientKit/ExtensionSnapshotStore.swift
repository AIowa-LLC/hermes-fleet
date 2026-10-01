import Foundation

/// Errors from `ExtensionSnapshotStore`. None echo snapshot content.
public enum ExtensionSnapshotError: Error, Sendable, Equatable {
    /// Why a snapshot failed `validate()` (fixed reasons; no content).
    public enum InvalidReason: String, Sendable, Equatable {
        case tooManyGateways
        case badHandle
        case duplicateHandle
        case badLabel
        case countOutOfRange
        case hiddenSnapshotCarriesLabels
    }

    /// The encoded snapshot (or the file on disk) exceeds the size cap.
    case tooLarge
    /// The file was written by a schema this reader does not understand
    /// (newer app, older extension, or pre-v1 garbage). Consumers fall back to
    /// generic, content-free presentation.
    case unsupportedSchemaVersion(Int)
    /// The file exists but is not a valid snapshot (truncated, not JSON,
    /// out-of-bounds values).
    case corrupt
    /// The snapshot failed the writer-side bounds check.
    case invalid(InvalidReason)
    /// A filesystem operation failed (numeric Cocoa/POSIX code only).
    case io(Int)
}

/// A small, versioned JSON snapshot in the shared container.
///
/// Write side lives in the app target; read side is used by extensions.
///
/// Design notes:
/// - **Atomic**: written via `Data.write(options: .atomic)` (temp file + rename),
///   so a reader never sees a partially written file and a failed write leaves
///   the previous snapshot intact.
/// - **Size cap**: `maximumEncodedBytes` is enforced before writing (the
///   previous file is kept on rejection) and before decoding on read, so a
///   memory-limited extension never parses an oversized or hostile file.
/// - **Versioned**: the reader checks `schemaVersion` from a header-only decode
///   first; a different version fails closed. There is one schema today, so
///   "migration" means the writer simply replaces the file with the current
///   version on its next publish.
/// - **Protection class — `completeUntilFirstUserAuthentication`** (deliberate):
///   widgets, Live Activity updates and the NSE must read this file while the
///   device is locked, which is the normal state when a push arrives. The
///   stricter `complete` class would make the file unreadable whenever the
///   device is locked and defeat the feature; `none` would expose it on a device
///   that has not been unlocked since boot. The payload is limited to redacted,
///   non-sensitive display data (see `ExtensionSnapshot`), so the residual
///   exposure — readable after first unlock — is acceptable. Anything that needs
///   `complete` (the transcript cache) is never stored here. Before the first
///   unlock after a reboot the file is unreadable and extensions must show their
///   generic fallback.
/// - The directory is excluded from backup (the snapshot is rebuildable).
public struct ExtensionSnapshotStore: Sendable {
    /// Hard cap on the encoded file, bytes.
    public static let maximumEncodedBytes = 16 * 1024

    /// The file-protection class applied to every write.
    public static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    public let fileURL: URL
    private let container: FleetSharedContainer?
    private let byteCap: Int

    /// Store at the typed snapshot location of the shared container.
    public init(container: FleetSharedContainer) {
        self.container = container
        self.fileURL = container.url(for: .extensionSnapshot)
        self.byteCap = Self.maximumEncodedBytes
    }

    /// Store at an explicit file (tests).
    public init(fileURL: URL) {
        self.init(fileURL: fileURL, byteCap: Self.maximumEncodedBytes)
    }

    /// Test seam: a smaller cap to exercise the oversize path.
    init(fileURL: URL, byteCap: Int) {
        self.byteCap = byteCap
        self.container = nil
        self.fileURL = fileURL
    }

    // MARK: write

    public func write(_ snapshot: ExtensionSnapshot) throws {
        guard snapshot.schemaVersion == ExtensionSnapshot.currentSchemaVersion else {
            throw ExtensionSnapshotError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        try snapshot.validate()
        let data = try Self.encode(snapshot)
        guard data.count <= byteCap else {
            throw ExtensionSnapshotError.tooLarge
        }
        do {
            if let container {
                try container.prepareDirectory()
            } else {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw ExtensionSnapshotError.io((error as NSError).code)
        }
    }

    // MARK: read

    /// The current snapshot, or nil when none has been written.
    public func read() throws -> ExtensionSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let size, size > byteCap {
            throw ExtensionSnapshotError.tooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ExtensionSnapshotError.io((error as NSError).code)
        }
        guard data.count <= byteCap else {
            throw ExtensionSnapshotError.tooLarge
        }
        let decoder = Self.makeDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw ExtensionSnapshotError.corrupt
        }
        guard header.schemaVersion == ExtensionSnapshot.currentSchemaVersion else {
            throw ExtensionSnapshotError.unsupportedSchemaVersion(header.schemaVersion)
        }
        let snapshot: ExtensionSnapshot
        do {
            snapshot = try decoder.decode(ExtensionSnapshot.self, from: data)
            try snapshot.validate()
        } catch {
            throw ExtensionSnapshotError.corrupt
        }
        return snapshot
    }

    /// Remove the snapshot (for example when the last gateway is removed or on
    /// reset). A missing file is a no-op.
    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw ExtensionSnapshotError.io((error as NSError).code)
        }
    }

    // MARK: coding

    private struct Header: Decodable {
        let schemaVersion: Int
    }

    static func encode(_ snapshot: ExtensionSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(snapshot)
        } catch {
            throw ExtensionSnapshotError.corrupt
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
