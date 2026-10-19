import SwiftUI
import UIKit
import QuickLook
import FleetCore

/// Composer attachment previews.
///
/// R10-T1 staged photos, PDFs, and files on the gateway but surfaced them as a
/// text chip (`name · size`) with no way to see what was attached. This adds
/// the two reads the tray was missing:
///
/// - a thumbnail for a picked photo (ImageIO downsample, so a 10 MB JPEG never
///   decodes at full size to fill a 32 pt chip),
/// - a full preview sheet: pinch-zoom for images, QuickLook for documents
///   (PDF and the Office/iWork/text families), and an explicit "no preview"
///   state for everything the app cannot render honestly.
///
/// The bytes previewed here are the exact bytes that were staged on the
/// gateway, held only for the life of the pending attachment (cleared on
/// send/remove). Nothing is uploaded again, and the preview never invents a
/// file that was not staged.

// MARK: - Thumbnail

/// Downsampling helper for chip thumbnails. ImageIO reads the header and
/// produces a small image without decoding the full frame, so a large photo
/// does not cost a full-size bitmap just to render a 32 pt glyph.
enum AttachmentPreviewThumbnail {
    /// The chip renders at 32 pt; 96 px covers @3x with headroom.
    static let maxPixelSize = 96

    static func pngData(from bytes: Data, maxPixelSize: Int = maxPixelSize) -> Data? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(
                bytes as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: thumbnail).pngData()
    }
}

// MARK: - Chip

/// One pending composer attachment: thumbnail (or document glyph), name and
/// size, tap to preview, X to remove. The accessibility identifier of the
/// chip itself is unchanged from R10-T1 so the existing UI tests keep
/// addressing the same element.
struct AttachmentChip: View {
    @Environment(\.fleetTheme) private var theme
    let attachment: ConversationViewModel.PendingAttachment
    var onOpen: () -> Void
    var onRemove: () -> Void

    @State private var thumbnail: UIImage?

    private var kind: AttachmentPreviewKind { attachment.previewKind }
    /// A staged file with retained bytes can always be opened: for an
    /// unsupported type the sheet explains itself rather than the chip sitting
    /// dimmed with no answer.
    private var canOpen: Bool { attachment.previewBytes != nil }

    private var openHint: String {
        kind == .unsupported
            ? "Explains why this file type has no preview"
            : "Opens the attachment preview"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    leadingGlyph
                    Text(attachment.caption)
                        .font(.caption)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            .accessibilityLabel("Preview \(attachment.displayName)")
            .accessibilityHint(openHint)
            .accessibilityIdentifier(
                "fleet.conversation.attachment.preview.\(attachment.displayName)")

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityLabel("Remove attachment \(attachment.displayName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                .fill(theme.surfaceElevated))
        .overlay(
            RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                .strokeBorder(theme.border, lineWidth: 1))
        // `.contain`, not `.combine`: the chip now holds two actions (open the
        // preview, remove the attachment) and combining would swallow both.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.conversation.attachment.chip.\(attachment.displayName)")
        .task(id: attachment.id) { await loadThumbnail() }
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        switch kind {
        case .image:
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            } else {
                placeholderGlyph(systemName: "photo")
            }
        case .document:
            placeholderGlyph(systemName: "doc.text")
        case .unsupported:
            placeholderGlyph(systemName: "paperclip")
        }
    }

    private func placeholderGlyph(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.caption2)
            .foregroundStyle(theme.highlight)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(theme.background))
            .accessibilityHidden(true)
    }

    /// Downsample off the main actor: the chip is built while the tray
    /// animates in, and a full decode of a large photo there is a visible
    /// hitch. Only the small PNG crosses back.
    private func loadThumbnail() async {
        guard kind == .image, thumbnail == nil, let bytes = attachment.previewBytes else { return }
        let downsampled = await Task.detached(priority: .utility) {
            AttachmentPreviewThumbnail.pngData(from: bytes)
        }.value
        guard !Task.isCancelled, let downsampled, let image = UIImage(data: downsampled) else { return }
        thumbnail = image
    }
}

// MARK: - Sheet

/// Full preview of one pending attachment. Images pinch-zoom; documents open
/// in QuickLook from a temporary copy of the staged bytes; anything else says
/// so plainly instead of showing an empty container.
struct AttachmentPreviewSheet: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let attachment: ConversationViewModel.PendingAttachment

    @State private var image: UIImage?
    @State private var previewURL: URL?
    @State private var prepared = false

    private var kind: AttachmentPreviewKind { attachment.previewKind }

    var body: some View {
        NavigationStack {
            Group {
                switch kind {
                case .image: imageContent
                case .document: documentContent
                case .unsupported: unsupportedContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
            .navigationTitle(attachment.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("fleet.conversation.attachment.preview.done")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let previewURL {
                        ShareLink(item: previewURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("fleet.conversation.attachment.preview.share")
                    }
                }
            }
        }
        .task(id: attachment.id) { prepare() }
        // The preview copy lives only while the sheet is up: a document is
        // never left behind in the app's temp directory after the user closes
        // it.
        .onDisappear { AttachmentPreviewFileStore.remove(previewURL) }
        .accessibilityIdentifier("fleet.conversation.attachment.preview")
    }

    @ViewBuilder
    private var imageContent: some View {
        if let image {
            ZoomableAttachmentImage(image: image)
        } else {
            unavailable(
                title: "Preview isn't available",
                detail: "The app couldn't decode this image. It is still attached to your next message.")
        }
    }

    @ViewBuilder
    private var documentContent: some View {
        if let previewURL {
            QuickLookAttachmentPreview(url: previewURL)
                .accessibilityIdentifier("fleet.conversation.attachment.preview.document")
        } else {
            unavailable(
                title: "Preview isn't available",
                detail: "The app couldn't open this document. It is still attached to your next message.")
        }
    }

    private var unsupportedContent: some View {
        unavailable(
            title: "No preview for this file type",
            detail: "\(attachment.displayName) is attached to your next message. The app can't render this format.")
            .accessibilityIdentifier("fleet.conversation.attachment.preview.unsupported")
    }

    private func unavailable(title: String, detail: String) -> some View {
        VStack(spacing: FleetTheme.spacingSm) {
            Image(systemName: "doc.questionmark")
                .font(.largeTitle)
                .foregroundStyle(theme.textSecondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(FleetTheme.spacingXl)
    }

    /// Resolve the preview sources once per attachment (not per body pass):
    /// `UIImage(data:)` is lazy, but writing a document copy is real disk I/O
    /// and must never run during a body evaluation.
    private func prepare() {
        guard !prepared else { return }
        prepared = true
        guard let bytes = attachment.previewBytes else { return }
        switch kind {
        case .image:
            image = UIImage(data: bytes)
        case .document:
            previewURL = AttachmentPreviewFileStore.write(
                bytes: bytes, displayName: attachment.displayName)
        case .unsupported:
            break
        }
    }
}

// MARK: - Zoom

/// Pinch-to-zoom for a previewed image. Double-tap returns to fit.
private struct ZoomableAttachmentImage: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1

    private static let maxScale: CGFloat = 6

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = min(max(settledScale * value.magnification, 1), Self.maxScale)
                    }
                    .onEnded { _ in settledScale = scale })
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    scale = 1
                    settledScale = 1
                }
            }
            .accessibilityLabel("Attachment image")
            .accessibilityIdentifier("fleet.conversation.attachment.preview.image")
    }
}

// MARK: - QuickLook

/// QuickLook host for a document preview copy. QuickLook covers the Office,
/// iWork, PDF, and text families with the system's own renderers — the app
/// ships no document decoder of its own.
private struct QuickLookAttachmentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.item = url as NSURL
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    /// `@preconcurrency`: `QLPreviewControllerDataSource` is a UIKit protocol
    /// whose callbacks arrive on the main thread, and this conformance only
    /// hands back the file URL it was constructed with.
    final class Coordinator: NSObject, @preconcurrency QLPreviewControllerDataSource {
        var item: NSURL

        init(url: URL) {
            self.item = url as NSURL
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            item
        }
    }
}

// MARK: - Preview file staging

/// The app-managed temp directory holding document preview copies. This type
/// is its only writer, `remove` is its cleanup path, and `remove` refuses any
/// URL outside the directory.
enum AttachmentPreviewFileStore {
    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-attachment-previews", isDirectory: true)
    }

    /// Write the staged bytes under their sanitized display name (QuickLook
    /// infers the type from the extension). Nil when the write fails — the
    /// sheet then shows its honest failure state.
    static func write(bytes: Data, displayName: String) -> URL? {
        let name = AttachmentPreviewRules.previewFileName(displayName: displayName)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try bytes.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Delete a preview copy. Only files inside `directory` are touched.
    static func remove(_ url: URL?) {
        guard let url,
              url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
