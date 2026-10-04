import CoreTransferable
import FleetCore
import Foundation
import UniformTypeIdentifiers

/// Size-checked access to picker-supplied content.
///
/// `PhotosPickerItem.loadTransferable(type: Data.self)` and `Data(contentsOf:)`
/// materialize the whole item before any cap can run, so an oversized photo or
/// file is fully in memory by the time it is rejected. Everything here checks
/// the on-disk size first and reads at most `limit` bytes.
enum BoundedPickedFile {
    struct TooLarge: Error { let sizeBytes: Int }
    struct SizeUnavailable: Error {}

    /// On-disk size of `url`; throws when it cannot be determined (fail closed).
    static func size(of url: URL) throws -> Int {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw SizeUnavailable()
        }
        return size
    }

    /// Reads `url` only when it fits `limit`; never reads more than `limit + 1`
    /// bytes (a file that grows after the size check is still caught).
    static func read(_ url: URL, limit: Int) throws -> Data {
        let size = try size(of: url)
        guard size <= limit else { throw TooLarge(sizeBytes: size) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw TooLarge(sizeBytes: data.count) }
        return data
    }
}

/// Photo-picker bytes for chat attachments, capped at the attachment limit
/// BEFORE the content is read into memory.
struct PickedAttachmentData: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            do {
                return PickedAttachmentData(
                    data: try BoundedPickedFile.read(received.file, limit: AttachmentStagingRules.clientCapBytes))
            } catch let error as BoundedPickedFile.TooLarge {
                throw AttachmentStagingError.fileTooLarge(
                    name: "photo", sizeBytes: error.sizeBytes,
                    capBytes: AttachmentStagingRules.clientCapBytes)
            }
        }
    }
}

/// Photo-picker bytes for bot avatars, capped at the avatar input limit.
struct PickedAvatarData: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedAvatarData(
                data: try BoundedPickedFile.read(received.file, limit: BotAvatarImageNormalization.maxInputBytes))
        }
    }
}
