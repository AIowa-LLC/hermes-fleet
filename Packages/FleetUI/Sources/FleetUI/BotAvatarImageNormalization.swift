import UIKit

/// i7-gapfill R1 — the avatar image staging policy, extracted from
/// `BotAvatarEditor` so the caps and normalization are unit-testable at the
/// hosted level. BEHAVIOR-IDENTICAL to the in-view code it replaces:
/// the 20 MB input cap is enforced at the Files-import call site (URL file
/// size, as before); `normalize` rejects undecodable/zero-sized input,
/// caps the long edge at 1024 px (scale-1 render, never upscaling), and
/// requires the staged JPEG to fit the 2 MB gateway upload cap.
enum BotAvatarImageNormalization {
    /// 20 MB — the input cap enforced on Files imports (URL file size).
    static let maxInputBytes = 20_000_000
    /// 1024 px — the long-edge cap of the normalized output.
    static let maxEdge: CGFloat = 1024
    /// 2 MB — the gateway `profiles.set_asset` upload cap.
    static let maxUploadBytes = 2_000_000

    /// Input-size gate for the Files import path (URL file size before
    /// reading the bytes). Same bound the editor previously inlined.
    static func isInputSizeAllowed(_ byteCount: Int) -> Bool {
        byteCount <= maxInputBytes
    }

    enum Outcome {
        /// Normalized JPEG bytes ready to stage into the draft.
        case staged(Data)
        /// Undecodable data or a zero-sized image.
        case invalidImage
        /// Decodable + normalized, but the JPEG still exceeds the upload cap.
        case exceedsUploadCap
    }

    static func normalize(_ bytes: Data) -> Outcome {
        guard let image = UIImage(data: bytes),
              image.size.width > 0, image.size.height > 0 else { return .invalidImage }
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = normalized.jpegData(compressionQuality: 0.85),
              data.count <= maxUploadBytes else { return .exceedsUploadCap }
        return .staged(data)
    }
}
