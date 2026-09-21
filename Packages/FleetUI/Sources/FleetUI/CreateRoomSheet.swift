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
    @Environment(\.fleetTheme) private var theme
    let environment: AppEnvironment
    /// Nil means the user entered from Chats and the host is selected after
    /// fleet-wide capability checks. Non-nil preserves the older scoped entry.
    let gateway: FleetGateway?
    let onCreated: (FleetRoom) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = RoomCreateDraft()
    @State private var setupID = UUID().uuidString
    @State private var compatibleGateways: Set<GatewayID> = []
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var eligibility: [Route: String] = [:]
    @State private var eligibilityReady = false

    public init(
        environment: AppEnvironment,
        gateway: FleetGateway,
        onCreated: @escaping (FleetRoom) -> Void
    ) {
        self.environment = environment
        self.gateway = gateway
        self.onCreated = onCreated
    }

    /// Fleet-wide entry point. Hosting is selected by the environment from
    /// authoritative capability and RoomLink probes.
    public init(
        environment: AppEnvironment,
        onCreated: @escaping (FleetRoom) -> Void
    ) {
        self.environment = environment
        self.gateway = nil
        self.onCreated = onCreated
    }

    /// Member candidates: this gateway's bots plus compatible remote
    /// gateways' bots (source-qualified by Route) — slice 10.
    private var candidates: [RoomMemberCandidate] {
        let bots: [FleetBot]
        if let gateway {
            bots = ([gateway.id] + compatibleGateways.sorted { $0.rawValue < $1.rawValue })
                .flatMap { environment.bots(on: $0) }
        } else {
            // Live data wins for an exact route; cached ghosts remain visible
            // and will be rendered as unavailable rather than omitted.
            var byRoute: [Route: FleetBot] = [:]
            for bot in environment.cachedBotsByGateway.values.flatMap({ $0 }) {
                byRoute[bot.route] = bot
            }
            for bot in environment.rosterSnapshot?.roster.allBots ?? [] {
                byRoute[bot.route] = bot
            }
            bots = byRoute.values.filter {
                environment.gateway(for: $0.route.gatewayID) != nil
            }
        }
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
                            // FOS-5 (SPEC §9): user-facing "Group"; room
                            // stays the internal identity term.
                            Label("New Group", systemImage: "person.3")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(theme.textPrimary)
                            TextField("Group name", text: $draft.name)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("fleet.room.create.name")
                            if let gateway {
                                Text("Hosted by \(gateway.displayName) — 2 to 6 members, frozen roster.")
                                    .font(FleetTheme.monoCaptionFont)
                                    .foregroundStyle(theme.textSecondary)
                            } else {
                                Text("Fleet-wide Group — the best eligible host is selected automatically. Pick 2 to 6 Bots from connected gateways.")
                                    .font(FleetTheme.monoCaptionFont)
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }

                    FleetCard {
                        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                            Label("Members (\(draft.members.count)/\(RoomCreateDraft.maxMembers))",
                                  systemImage: "person.2")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(theme.textPrimary)
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
                                            .background(Capsule().fill(theme.surfaceElevated))
                                        }
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                        SectionHeader(title: "Pick Bots")
                        if let gateway, compatibleGateways.isEmpty {
                            Text("Bots on \(gateway.displayName). Remote gateways appear once direct RoomLink support is confirmed.")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(theme.textSecondary)
                        } else if let gateway {
                            Text("Bots on \(gateway.displayName) and \(compatibleGateways.count) linked gateway\(compatibleGateways.count == 1 ? "" : "s"). Each remote member is re-validated before creation.")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(theme.textSecondary)
                                .accessibilityIdentifier("fleet.room.create.linked-note")
                        } else {
                            Text(eligibilityReady
                                 ? fleetWideNote
                                 : "Checking connected gateways and RoomLink eligibility…")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(theme.textSecondary)
                                .accessibilityIdentifier("fleet.room.create.fleet-note")
                        }
                        ForEach(visibleCandidates) { candidate in
                            candidateRow(candidate)
                        }
                        if visibleCandidates.isEmpty {
                            Text(gateway == nil ? "No Bots are available from the connected fleet yet." : "No bots on this gateway yet.")
                                .font(FleetTheme.secondaryFont)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                .padding(FleetTheme.spacingLg)
            }
            .background(theme.background.ignoresSafeArea())
            .searchable(text: $searchText, prompt: gateway.map { "Bots on \($0.displayName)" } ?? "Bots across every gateway")
            .task {
                if let gateway {
                    compatibleGateways = await environment.compatibleRoomGateways(homeID: gateway.id)
                } else {
                    var results: [Route: String] = [:]
                    for candidate in candidates {
                        if let reason = await environment.roomEligibilityMessage(for: candidate.route) {
                            results[candidate.route] = reason
                        }
                    }
                    eligibility = results
                    eligibilityReady = true
                }
            }
            .navigationTitle("Create Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text("Create Group") }
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

    /// Honest fleet-wide note: same-gateway groups always work; mixing
    /// gateways needs RoomLink direct endpoints (a gateway-side setting) —
    /// surfaced up front instead of failing at create time.
    private var fleetWideNote: String {
        let crossGateway = Set(draft.members.map { $0.route.gatewayID }).count > 1
        if crossGateway {
            return "Mixing Bots from different gateways runs this Group on your iPhone — every member still replies. Same-gateway groups run on a gateway."
        }
        return "Each Bot keeps its owning gateway identity. Offline or unsupported participants remain visible with the reason they cannot be selected."
    }

    private func candidateRow(_ candidate: RoomMemberCandidate) -> some View {
        let selected = draft.members.contains { $0.id == candidate.id }
        let presence = environment.botPresence(for: candidate.route)
        let reason = eligibility[candidate.route]
        let selectable = gateway != nil
            ? presence == .reachable
            : eligibilityReady && presence == .reachable && reason == nil
        return Button {
            draft.toggle(candidate)
        } label: {
            // FOS-6: operational row (member candidate picker).
            FleetListRow {
                HStack(spacing: FleetTheme.spacingMd) {
                    BotAvatar(bot: environment.botIncludingGhost(for: candidate.route), management: environment.botManagement)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                        let ownerGateway = environment.gateway(for: candidate.route.gatewayID)?.displayName ?? candidate.route.gatewayID.rawValue
                        Text("\(candidate.route.profileSlug.rawValue) · \(ownerGateway)")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(theme.textSecondary)
                        if let reason {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(FleetTheme.statusNeedsIntervention)
                        } else if presence == .reachable {
                            Text("Available")
                                .font(.caption2)
                                .foregroundStyle(FleetTheme.statusOnline)
                        } else {
                            Text(presence == .unknown ? "Availability not confirmed" : "Gateway offline")
                                .font(.caption2)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? theme.highlight : theme.textSecondary)
                }
            }
        }
        .disabled(!selectable)
        .buttonStyle(.fleetPressable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(candidate.displayName), \(candidate.route.profileSlug.rawValue), owned by \(environment.gateway(for: candidate.route.gatewayID)?.displayName ?? candidate.route.gatewayID.rawValue)\(reason.map { ", \($0)" } ?? (selectable ? "" : ", unavailable"))")
        // Keep the established profile-only identifiers for Bots owned by
        // the gateway that opened this sheet. Linked candidates stay
        // route-qualified so an identical profile slug cannot make the
        // legacy gateway-context UI ambiguous. Chats always uses the
        // route-qualified form for the fleet-wide picker.
        .accessibilityIdentifier({
            if gateway == nil { return "fleet.room.create.candidate.\(candidate.route.id)" }
            if candidate.route.gatewayID == gateway?.id {
                return "fleet.room.create.candidate.\(candidate.route.profileSlug.rawValue)"
            }
            return "fleet.room.create.candidate.\(candidate.route.id)"
        }())
    }

    private func submit() async {
        guard draft.canSubmit else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let room: FleetRoom
            if let gateway {
                room = try await environment.createRoom(
                    gatewayID: gateway.id, name: draft.name, members: draft.members, setupID: setupID)
            } else {
                room = try await environment.createRoom(
                    name: draft.name, members: draft.members, setupID: setupID)
            }
            onCreated(room)
            dismiss()
        } catch {
            errorMessage = RoomChatViewModel.explain(error)
        }
    }
}
