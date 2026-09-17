import SwiftUI
import FleetCore

/// Card D — inline generated-image artifacts.
///
/// One artifact reference renders through the shared `ArtifactImageStore`
/// (dedupe: one fetch per reference, reused by every surface). States are
/// honest: loading, the real bytes, or a typed failure with the expiration
/// class called out (never a broken-image placeholder, never a fabricated
/// "still on its way").
struct ConversationArtifactView: View {
    @Environment(\.fleetTheme) private var theme
    let reference: ArtifactReference
    let environment: AppEnvironment
    /// Accessibility/identifier stem — the CITING row id, so two artifacts on
    /// one screen never collide.
    let identifier: String

    @State private var showingPreview = false

    private var store: ArtifactImageStore { environment.artifactImages }

    var body: some View {
        ArtifactStateView(
            reference: reference,
            state: store.state(for: reference),
            image: store.image(for: reference),
            retrieverAvailable: environment.makeArtifactRetriever(for: reference.gatewayID) != nil,
            identifier: identifier,
            onOpen: { showingPreview = true },
            onRetry: { Task { await retry() } }
        )
        .task(id: reference) { await load() }
        .sheet(isPresented: $showingPreview) {
            ArtifactPreviewSheet(
                reference: reference,
                environment: environment,
                state: store.state(for: reference),
                image: store.image(for: reference),
                onRetry: { Task { await retry() } })
        }
    }

    private func load() async {
        guard store.state(for: reference) == nil,
              let retriever = environment.makeArtifactRetriever(for: reference.gatewayID) else { return }
        await store.load(reference, using: retriever)
    }

    private func retry() async {
        guard let retriever = environment.makeArtifactRetriever(for: reference.gatewayID) else { return }
        await store.retry(reference, using: retriever)
    }
}

/// The state-driven presentation of one artifact (shared by the transcript
/// bubble and the Artifacts destination).
struct ArtifactStateView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reference: ArtifactReference
    let state: ArtifactImageStore.State?
    let image: UIImage?
    let retrieverAvailable: Bool
    let identifier: String
    var onOpen: () -> Void = {}
    var onRetry: () -> Void = {}

    var body: some View {
        Group {
            switch resolvedState {
            case .loading:
                loadingCard
            case .loaded:
                loadedCard
            case .failed(let error):
                failureCard(ArtifactRetrievalCopy.failure(for: error))
            }
        }
        // Card E: the retrieval phases cross-fade (loading → delivered image /
        // failure card) so the final swap of a generation handoff never pops;
        // Reduce Motion swaps instantly.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: resolvedState)
    }

    /// `nil` state with no transport wired is the fail-closed "unavailable"
    /// answer (never a spinner that can never resolve).
    private var resolvedState: ArtifactImageStore.State {
        if let state { return state }
        return retrieverAvailable ? .loading : .failed(.notConfigured)
    }

    private var loadingCard: some View {
        HStack(spacing: FleetTheme.spacingSm) {
            ProgressView().controlSize(.small)
            Text("Loading \(reference.displayName)…")
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.artifact.loading.\(identifier)")
    }

    @ViewBuilder
    private var loadedCard: some View {
        if let image {
            Button(action: onOpen) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).strokeBorder(theme.border, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Generated image \(reference.displayName)")
            .accessibilityHint("Opens the image with sharing options")
            .accessibilityIdentifier("fleet.artifact.image.\(identifier)")
        } else {
            // Retrieved bytes exist but the platform cannot decode them for a
            // preview (e.g. SVG) — say so, and keep sharing available.
            HStack(spacing: FleetTheme.spacingSm) {
                Image(systemName: "photo").foregroundStyle(theme.textSecondary)
                Text("\(reference.displayName) — preview isn't available for this format")
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(theme.border, lineWidth: 1))
        .onTapGesture(perform: onOpen)
        .accessibilityIdentifier("fleet.artifact.undecodable.\(identifier)")
        }
    }

    private func failureCard(_ failure: ArtifactRetrievalCopy.Failure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(failure.title, systemImage: "photo.badge.exclamationmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
            Text(failure.detail)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if failure.canRetry {
                Button("Retry") { onRetry() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.highlight)
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("fleet.artifact.retry.\(identifier)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(theme.border, lineWidth: 1))
        .accessibilityIdentifier("fleet.artifact.failure.\(identifier)")
    }
}

/// Full-screen preview of one artifact: the image at size, its provenance
/// (gateway + source conversation), and sharing (the retrieved bytes written
/// to a temp file under the app's own name — never the gateway path).
struct ArtifactPreviewSheet: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let reference: ArtifactReference
    let environment: AppEnvironment
    let state: ArtifactImageStore.State?
    let image: UIImage?
    var onRetry: () -> Void = {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                    switch state {
                    case .loaded:
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .accessibilityIdentifier("fleet.artifact.preview.image")
                        } else {
                            Text("Preview isn't available for this format. You can still share the file.")
                                .font(.footnote)
                                .foregroundStyle(theme.textSecondary)
                        }
                        shareRow
                    case .failed(let error):
                        failureBody(ArtifactRetrievalCopy.failure(for: error))
                    case .loading, .none:
                        HStack(spacing: FleetTheme.spacingSm) {
                            ProgressView().controlSize(.small)
                            Text("Retrieving \(reference.displayName)…")
                                .font(.footnote)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    provenance
                }
                .padding()
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle(reference.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("fleet.artifact.preview")
    }

    @ViewBuilder
    private var shareRow: some View {
        if let url = environment.artifactImages.shareFileURL(for: reference) {
            ShareLink(item: url, preview: SharePreview(reference.displayName)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("fleet.artifact.share")
        }
    }

    private func failureBody(_ failure: ArtifactRetrievalCopy.Failure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.title, systemImage: "photo.badge.exclamationmark")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("fleet.artifact.preview.failure")
            Text(failure.detail)
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
            if failure.canRetry {
                Button("Retry") { onRetry() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.highlight)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("fleet.artifact.preview.retry")
            }
        }
    }

    /// Provenance: which gateway hosts the bytes and which conversation cited
    /// them. The gateway-local path never renders.
    private var provenance: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SOURCE")
                .font(FleetTheme.sectionHeaderFont)
                .tracking(0.8)
                .foregroundStyle(theme.textSecondary)
            Text(environment.gateway(for: reference.gatewayID)?.displayName ?? reference.gatewayID.rawValue)
                .font(.subheadline)
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("fleet.artifact.preview.gateway")
            if let profile = reference.profile {
                Text(profile)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}
