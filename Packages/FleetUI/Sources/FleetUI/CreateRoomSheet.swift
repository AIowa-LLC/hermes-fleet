import SwiftUI
import FleetCore

/// TRUE BOTS MODE slice 4 (D15) — create a hosted room: name + 2-6
/// source-qualified members picked from the fleet roster (bot candidates,
/// each carrying its owning gateway — D18 identity preserved through
/// creation).
///
/// Capability honesty: the sheet is only REACHED from a gateway whose rooms
/// advertise `groups.create`; if capabilities change under it mid-flight,
/// the VM fails with the typed unsupported explanation (update-gateway
/// copy), never a semantic fallback.
public struct CreateRoomSheet: View {
    let environment: AppEnvironment
    let gateway: FleetGateway
    let onCreated: (FleetRoom) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = RoomCreateDraft()
    @State private var setupID = UUID().uuidString
    @State private var compatibleGateways: Set<GatewayID> = []
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    public init(
        environment: AppEnvironment,
        gateway: FleetGateway,
        onCreated: @escaping (FleetRoom) -> Void
    ) {
        self.environment = environment
        self.gateway = gateway
        self.onCreated = onCreated
    }

    /// Member candidates: this gateway's bots plus compatible remote
    /// gateways' bots (source-qualified by Route) — slice 10.
    private var candidates: [RoomMemberCandidate] {
        let bots = ([gateway.id] + compatibleGateways.sorted { $0.rawValue < $1.rawValue }).flatMap { environment.bots(on: $0) }
        return BotRosterPresentation.order(bots).compactMap { bot in
            RoomMemberCandidate(route: bot.route, displayName: BotRosterPresentation.displayTitle(for: bot))
        }
    }

    private var visibleCandidates: [RoomMemberCandidate] {
        let ordered = candidates
        guard !searchText.isEmpty else { return ordered }
        return ordered.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.route.profileSlug.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
                    FleetCard {
                        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                            Label("New Room", systemImage: "person.3")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(FleetTheme.textPrimary)
                            TextField("Room name", text: $draft.name)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("fleet.room.create.name")
                            Text("Hosted by \(gateway.displayName) — 2 to 6 members, frozen roster.")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(FleetTheme.textSecondary)
                        }
                    }

                    FleetCard {
                        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                            Label("Members (\(draft.members.count)/\(RoomCreateDraft.maxMembers))",
                                  systemImage: "person.2")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(FleetTheme.textPrimary)
                                .accessibilityIdentifier("fleet.room.create.member-count")
                            if !draft.members.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: FleetTheme.spacingXs) {
                                        ForEach(draft.members) { member in
                                            HStack(spacing: 4) {
                                                Text(member.displayName)
                                                    .font(.caption.weight(.semibold))
                                                Button {
                                                    draft.toggle(member)
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.caption2)
                                                }
                                                .accessibilityLabel("Remove \(member.displayName)")
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Capsule().fill(FleetTheme.surfaceElevated))
                                        }
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                        SectionHeader(title: "Pick Bots")
                        if compatibleGateways.isEmpty {
                            Text("Bots on \(gateway.displayName). Remote gateways appear once direct RoomLink support is confirmed.")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(FleetTheme.textSecondary)
                        } else {
                            Text("Bots on \(gateway.displayName) and \(compatibleGateways.count) linked gateway\(compatibleGateways.count == 1 ? "" : "s"). Each remote member is re-validated before creation.")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(FleetTheme.textSecondary)
                                .accessibilityIdentifier("fleet.room.create.linked-note")
                        }
                        ForEach(visibleCandidates) { candidate in
                            candidateRow(candidate)
                        }
                        if visibleCandidates.isEmpty {
                            Text("No bots on this gateway yet.")
                                .font(FleetTheme.secondaryFont)
                                .foregroundStyle(FleetTheme.textSecondary)
                        }
                    }
                }
                .padding(FleetTheme.spacingLg)
            }
            .background(FleetTheme.background.ignoresSafeArea())
            .searchable(text: $searchText, prompt: "Bots on \(gateway.displayName)")
            .task { compatibleGateways = await environment.compatibleRoomGateways(homeID: gateway.id) }
            .navigationTitle("Create Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text("Create") }
                    }
                    .disabled(!draft.canSubmit || isSubmitting)
                    .accessibilityIdentifier("fleet.room.create.submit")
                }
            }
            .alert("Couldn't create the room", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func candidateRow(_ candidate: RoomMemberCandidate) -> some View {
        let selected = draft.members.contains { $0.id == candidate.id }
        return Button {
            draft.toggle(candidate)
        } label: {
            FleetCard {
                HStack(spacing: FleetTheme.spacingMd) {
                    BotAvatar(bot: environment.bot(for: candidate.route), management: environment.botManagement)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(FleetTheme.textPrimary)
                        let ownerGateway = environment.gateway(for: candidate.route.gatewayID)?.displayName ?? candidate.route.gatewayID.rawValue
                        Text("\(candidate.route.profileSlug.rawValue) · \(ownerGateway)")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? FleetTheme.accent : FleetTheme.textSecondary)
                }
            }
        }
        .buttonStyle(.fleetPressable)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.room.create.candidate.\(candidate.route.profileSlug.rawValue)")
    }

    private func submit() async {
        guard draft.canSubmit else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let room = try await environment.createRoom(
                gatewayID: gateway.id, name: draft.name, members: draft.members, setupID: setupID)
            onCreated(room)
            dismiss()
        } catch {
            errorMessage = RoomChatViewModel.explain(error)
        }
    }
}
