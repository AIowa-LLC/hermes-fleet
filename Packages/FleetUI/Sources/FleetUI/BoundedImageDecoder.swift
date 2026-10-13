import Foundation
import ImageIO
import UIKit

/// Decodes untrusted image bytes with a hard pixel budget.
///
/// A compressed image can declare enormous dimensions (a few KB of data that
/// expands to gigabytes of bitmap). Every decode of gateway- or picker-supplied
/// bytes goes through here: dimensions are read from the header first, images
/// over `maxSourcePixels` are refused, and accepted images are decoded as a
/// thumbnail capped at `maxDecodedDimension`, never at full resolution.
enum BoundedImageDecoder {
    /// Largest source image accepted (width × height): 48 megapixels.
    static let maxSourcePixels = 48_000_000
    /// Longest edge of any decoded bitmap held in memory.
    static let maxDecodedDimension: CGFloat = 4096

    /// Pixel dimensions from the image header, without decoding the bitmap.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func isWithinBudget(width: Int, height: Int, maxPixels: Int = maxSourcePixels) -> Bool {
        // Divide rather than multiply: no overflow for hostile dimensions.
        width <= maxPixels / max(height, 1)
    }

    /// Decode within the pixel budget; nil when the data is not an image or
    /// declares more than `maxPixels` pixels.
    static func decode(
        _ data: Data,
        maxPixels: Int = maxSourcePixels,
        maxDimension: CGFloat = maxDecodedDimension
    ) -> UIImage? {
        guard let size = pixelSize(of: data),
              isWithinBudget(width: size.width, height: size.height, maxPixels: maxPixels),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            // Never upscale: cap at the smaller of the budget and the source edge.
            kCGImageSourceThumbnailMaxPixelSize: min(Int(maxDimension), max(size.width, size.height)),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
