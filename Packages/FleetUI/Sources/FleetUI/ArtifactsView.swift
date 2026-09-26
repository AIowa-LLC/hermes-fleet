import SwiftUI
import FleetCore

/// Card D — the Artifacts destination: every generated-image artifact THIS
/// device has observed, grouped by the gateway that hosts it, with the source
/// conversation recorded at capture time. Browse → preview → share; retrieval
/// is live per row (the gateway stays the source of truth), and expiration is
/// surfaced truthfully.
///
/// This list is device-local by construction: the gateway publishes no media
/// listing API, so nothing here claims fleet-wide state, and no sync is
/// simulated.
struct ArtifactsView: View {
    @Environment(\.fleetTheme) private var theme
    let environment: AppEnvironment

    @State private var entries: [FleetArtifactLibrary.Entry] = []
    @State private var previewTarget: PreviewTarget?

    /// Entries grouped by gateway, preserving newest-first order.
    private var sections: [(gatewayID: GatewayID, entries: [FleetArtifactLibrary.Entry])] {
        var order: [GatewayID] = []
        var grouped: [GatewayID: [FleetArtifactLibrary.Entry]] = [:]
        for entry in entries {
            let id = entry.gatewayID
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(entry)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No artifacts yet",
                    systemImage: "photo.on.rectangle",
                    description: Text("Images your agents generate in conversations will collect here, with the conversation they came from."))
                    .accessibilityIdentifier("fleet.artifacts.empty")
            }
            ForEach(sections, id: \.gatewayID) { section in
                Section {
                    ForEach(Array(section.entries.enumerated()), id: \.element.id) { offset, entry in
                        row(entry: entry, index: offset)
                    }
                } header: {
                    Text(gatewayName(section.gatewayID))
                } footer: {
                    Text("Collected on this device from your conversations.")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .navigationTitle("Artifacts")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .refreshable { reload() }
        .sheet(item: $previewTarget) { target in
            ArtifactPreviewSheet(
                reference: target.reference,
                environment: environment,
                state: environment.artifactImages.state(for: target.reference),
                image: environment.artifactImages.image(for: target.reference),
                onRetry: { Task { await retry(target.reference) } })
        }
        .accessibilityIdentifier("fleet.artifacts")
    }

    /// Sheet identity wrapper (the reference itself is not Identifiable).
    private struct PreviewTarget: Identifiable {
        let reference: ArtifactReference
        var id: String { "\(reference.gatewayID.rawValue)|\(reference.path)|\(reference.sessionID ?? "")" }
    }

    private func row(entry: FleetArtifactLibrary.Entry, index: Int) -> some View {
        Button {
            previewTarget = PreviewTarget(reference: entry.reference)
        } label: {
            HStack(spacing: FleetTheme.spacingMd) {
                ArtifactThumbnail(reference: entry.reference, environment: environment)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(sourceLine(entry))
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel("\(entry.name), \(sourceLine(entry))")
        .accessibilityIdentifier("fleet.artifacts.row.\(index)")
    }

    /// Provenance line: the source conversation (captured at citation time)
    /// plus the profile scope. Never the gateway-local path.
    private func sourceLine(_ entry: FleetArtifactLibrary.Entry) -> String {
        let conversation = entry.sourceTitle.map { "From “\($0)”" } ?? "From a conversation"
        if let profile = entry.profile {
            return "\(conversation) · \(profile)"
        }
        return conversation
    }

    private func gatewayName(_ id: GatewayID) -> String {
        environment.gateway(for: id)?.displayName ?? id.rawValue
    }

    private func reload() {
        entries = environment.artifactLibrary.entries()
    }

    private func retry(_ reference: ArtifactReference) async {
        guard let retriever = environment.makeArtifactRetriever(for: reference.gatewayID) else { return }
        await environment.artifactImages.retry(reference, using: retriever)
    }
}

/// Small square preview for one artifact row (loads through the shared store;
/// a still-loading or failed row shows the neutral placeholder — the row's
/// text carries the honest state).
private struct ArtifactThumbnail: View {
    @Environment(\.fleetTheme) private var theme
    let reference: ArtifactReference
    let environment: AppEnvironment

    var body: some View {
        Group {
            if let image = environment.artifactImages.image(for: reference) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .frame(width: 56, height: 56)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.border, lineWidth: 1))
        .accessibilityHidden(true)
        .task(id: reference) {
            guard environment.artifactImages.state(for: reference) == nil,
                  let retriever = environment.makeArtifactRetriever(for: reference.gatewayID) else { return }
            await environment.artifactImages.load(reference, using: retriever)
        }
    }
}
