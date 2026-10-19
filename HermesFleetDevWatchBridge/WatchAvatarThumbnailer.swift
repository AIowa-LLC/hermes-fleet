import Foundation
import ImageIO
import UniformTypeIdentifiers
import FleetWatchKit

/// Shrinks a bot's avatar to Watch size. Decoding is bounded (pixel budget,
/// thumbnail decode, never a full-size bitmap) and the output must fit one
/// WatchConnectivity message, or there is no thumbnail and the Watch keeps
/// drawing the bot's shape.
enum WatchAvatarThumbnailer {
    /// Large enough for the biggest Watch avatar (56 pt at 2x).
    static let edge = 112
    static let maxSourcePixels = 40_000_000

    static func thumbnail(from source: Data) -> Data? {
        guard let image = CGImageSourceCreateWithData(source as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= maxSourcePixels else { return nil }
        for (edge, type, quality) in [(edge, UTType.png, 1.0), (edge, .jpeg, 0.75), (72, .jpeg, 0.6)] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(edge, max(width, height)),
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary),
                  let data = encode(thumb, as: type, quality: quality) else { continue }
            if data.count <= WatchAvatarImage.maxBytes { return data }
        }
        return nil
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
