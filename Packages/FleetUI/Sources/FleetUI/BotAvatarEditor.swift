import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import FleetCore

/// Asset writes are independent of the profile form and report their own result.
struct BotAvatarEditor: View {
    let environment: AppEnvironment
    let bot: FleetBot
    @State private var supportsAssets = false
    @State private var supportsGeneration = false
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var generating = false
    @State private var style = ""
    @State private var preview: Data?
    @State private var working = false
    @State private var status: String?
    @State private var confirmingClear = false

    private var currentBot: FleetBot { environment.bot(for: bot.route) ?? bot }

    var body: some View {
        BotAvatar(bot: currentBot, management: environment.botManagement)
        if supportsAssets {
            PhotosPicker("Upload from Photos", selection: $photo, matching: .images)
                .accessibilityIdentifier("fleet.bot.avatar.photos")
                .disabled(working)
            Button("Upload from Files") { importing = true }
                .accessibilityIdentifier("fleet.bot.avatar.files")
                .disabled(working)
            if currentBot.hasAvatar {
                Button("Clear custom avatar", role: .destructive) { confirmingClear = true }
                    .accessibilityIdentifier("fleet.bot.avatar.clear")
                    .disabled(working)
            }
            if supportsGeneration {
                Button("Generate Portrait") { generating = true }
                    .accessibilityIdentifier("fleet.bot.avatar.generate")
                    .disabled(working)
            }
        } else {
            Text("Avatar uploads are unavailable until this gateway confirms asset support.")
                .font(.caption)
                .accessibilityIdentifier("fleet.bot.avatar.unsupported")
        }
        if working { ProgressView("Preparing avatar…") }
        if let status { Text(status).font(.caption).accessibilityIdentifier("fleet.bot.avatar.status") }
        if let preview, let image = UIImage(data: preview) {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                .accessibilityLabel("Portrait preview")
            Button("Use this portrait") { Task { await upload(preview) } }
                .disabled(working)
                .accessibilityIdentifier("fleet.bot.avatar.confirm")
            Button("Discard portrait", role: .cancel) { self.preview = nil }
        }
        Color.clear.frame(height: 0)
            .task {
                guard let seam = environment.botManagement.seam(for: bot.route.gatewayID) else { return }
                supportsAssets = await seam.supportsAvatarUpload(bot.profileSlug.rawValue)
                if supportsAssets { supportsGeneration = await seam.supportsPortraitGeneration() }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw BotPortraitError.invalidImage }
                        await upload(data)
                    } catch { status = "Could not read the selected photo." }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                Task {
                    do {
                        let url = try result.get()
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 20_000_000 else { throw BotPortraitError.invalidImage }
                        await upload(try Data(contentsOf: url))
                    } catch { status = "Could not read the selected image (maximum input size 20 MB)." }
                }
            }
            .alert("Generate Portrait", isPresented: $generating) {
                TextField("Description or style (optional)", text: $style)
                Button("Generate") { Task { await generate() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your gateway generates a preview. You choose whether to save it.") }
            .confirmationDialog("Clear custom avatar?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear Avatar", role: .destructive) {
                    Task {
                        working = true
                        defer { working = false }
                        do {
                            try await environment.botManagement.clearAvatar(bot)
                            await environment.refreshRoster()
                            status = "Custom avatar cleared."
                        } catch { status = "The gateway could not clear the avatar." }
                    }
                }
            }
    }

    private func generate() async {
        guard let seam = environment.botManagement.seam(for: bot.gatewayID) else { return }
        working = true
        defer { working = false }
        do {
            preview = try await seam.generatePortrait(prompt: "A square avatar portrait for a bot named \(BotRosterPresentation.displayTitle(for: bot)). \(style)")
            status = "Preview ready. Confirm to save this portrait."
        } catch { status = "Portrait generation failed on the gateway. Try again or upload an image." }
    }

    private func upload(_ bytes: Data) async {
        working = true
        defer { working = false }
        guard let image = UIImage(data: bytes), image.size.width > 0, image.size.height > 0 else {
            status = "Choose a valid image."; return
        }
        let scale = min(1, 1024 / max(image.size.width, image.size.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = normalized.jpegData(compressionQuality: 0.85), data.count <= 2_000_000 else {
            status = "Choose a smaller image (maximum upload 2 MB)."; return
        }
        do {
            try await environment.botManagement.uploadAvatar(bot, dataURL: "data:image/jpeg;base64," + data.base64EncodedString())
            await environment.refreshRoster()
            preview = nil
            status = "Avatar saved on the gateway."
        } catch { status = "The gateway could not save the avatar. Your previous avatar remains unchanged." }
    }
}
