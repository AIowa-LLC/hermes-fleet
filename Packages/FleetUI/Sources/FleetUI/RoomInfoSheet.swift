import SwiftUI
import FleetCore

/// RC-84 P1 — compact Group Info surface: the KNOWN, non-secret state of a
/// room (participants, gateway ownership, status, capabilities, revision).
///
/// Presentation-only over `FleetRoom` fields the gateway actually reported —
/// any datum the gateway has not provided stays "Unknown", never guessed
/// (capability honesty: the same rule the capability report follows).
public struct RoomInfoSheet: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    private let viewModel: RoomChatViewModel
    private let environment: AppEnvironment

    public init(viewModel: RoomChatViewModel, environment: AppEnvironment) {
        self.viewModel = viewModel
        self.environment = environment
    }

    private var room: FleetRoom { viewModel.room }

    public var body: some View {
        NavigationStack {
            List {
                Section("Room") {
                    LabeledContent("Name") { Text(room.name).multilineTextAlignment(.trailing) }
                    LabeledContent("Status") { Text(RoomInfoPresentation.statusText(room)) }
                    LabeledContent("Kind") { Text(RoomInfoPresentation.provenanceText(room)) }
                }
                Section("Gateways") {
                    LabeledContent("Home gateway") { Text(homeGatewayText) }
                    LabeledContent("Authority") {
                        Text(RoomInfoPresentation.authorityText(room))
                            .font(FleetTheme.monoCaptionFont)
                    }
                    LabeledContent("Room driver") { Text(RoomInfoPresentation.driverText(room)) }
                }
                Section {
                    if room.members.isEmpty {
                        Text("No participants reported for this Group.")
                            .foregroundStyle(theme.textSecondary)
                            .accessibilityIdentifier("fleet.room.info.participants.empty")
                    } else {
                        ForEach(Array(room.members.enumerated()), id: \.offset) { index, member in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.name)
                                if let detail = RoomInfoPresentation.participantDetail(member) {
                                    Text(detail)
                                        .font(.footnote)
                                        .foregroundStyle(theme.textSecondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("fleet.room.info.participant.\(index)")
                        }
                    }
                } header: {
                    Text("Participants")
                } footer: {
                    Text("Participants are the members the gateway reports for this room; gateway labels come from RoomLink identity when known.")
                }
                Section {
                    ForEach(RoomInfoPresentation.capabilityLines(room.capabilities)) { line in
                        HStack {
                            Text(line.label)
                            Spacer()
                            Image(systemName: line.supported ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(line.supported ? FleetTheme.statusOnline : theme.textSecondary)
                            Text(line.supported ? "Supported" : "Not supported")
                                .font(.footnote)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("fleet.room.info.capability.\(line.id)")
                    }
                } header: {
                    Text("Capabilities")
                } footer: {
                    Text("Capabilities reflect how the room was created and what the gateway advertises for it — never what the UI could render.")
                }
                Section("State") {
                    LabeledContent("Revision", value: "\(room.revision)")
                    LabeledContent("Last update") { Text(RoomInfoPresentation.lastUpdateText(room)) }
                }
            }
            .navigationTitle("Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("fleet.room.info.sheet")
        }
    }

    private var homeGatewayText: String {
        environment.gateway(for: room.id.gatewayID)?.displayName ?? room.id.gatewayID.rawValue
    }
}

/// Pure presentation mapping for the Group Info sheet (unit-tested). Every
/// function returns the honest string for the reported data; missing data
/// maps to "Unknown" rather than a guess.
public enum RoomInfoPresentation {

    public static func provenanceText(_ room: FleetRoom) -> String {
        switch room.id.provenance {
        case .hosted: return "Hosted Group"
        case .desktopLegacy: return "Managed by Hermes Desktop · read only"
        }
    }

    public static func statusText(_ room: FleetRoom) -> String {
        if room.isDeleted || room.hosted?.disbandedAt != nil { return "Disbanded" }
        return "Active"
    }

    public static func authorityText(_ room: FleetRoom) -> String {
        guard let hosted = room.hosted, !hosted.authorityGatewayID.isEmpty else { return "Unknown" }
        return hosted.authorityGatewayID
    }

    public static func driverText(_ room: FleetRoom) -> String {
        guard let hosted = room.hosted else { return "Unknown" }
        return hosted.driverAvailable ? "Available" : "Unavailable"
    }

    /// The best known non-secret identity line for a participant: the
    /// RoomLink connection label, else the handle, else a scoped note;
    /// genuinely-none becomes nil (no filler).
    public static func participantDetail(_ member: FleetRoomMember) -> String? {
        if let label = member.connectionLabel, !label.isEmpty { return label }
        if let handle = member.handle, !handle.isEmpty { return handle }
        return member.sourceScoped ? "Source-scoped participant" : nil
    }

    public static func lastUpdateText(_ room: FleetRoom) -> String {
        guard let updatedAt = room.hosted?.updatedAt else { return "Unknown" }
        return Date(timeIntervalSince1970: updatedAt).formatted(date: .abbreviated, time: .shortened)
    }

    public struct CapabilityLine: Hashable, Sendable, Identifiable {
        public let label: String
        public let supported: Bool
        /// Stable machine key (accessibility identifiers, tests).
        public let key: String

        public var id: String { key }
    }

    /// The capability surface in a stable display order (mirrors
    /// `RoomCapabilities`).
    public static func capabilityLines(_ capabilities: RoomCapabilities) -> [CapabilityLine] {
        [
            CapabilityLine(label: "Send messages", supported: capabilities.canSend, key: "send"),
            CapabilityLine(label: "Rename", supported: capabilities.canRename, key: "rename"),
            CapabilityLine(label: "Disband", supported: capabilities.canDisband, key: "disband"),
            CapabilityLine(label: "Stop a running turn", supported: capabilities.canStop, key: "stop"),
            CapabilityLine(label: "Retry a failed turn", supported: capabilities.canRetry, key: "retry"),
            CapabilityLine(label: "Approve requests", supported: capabilities.canApprove, key: "approve"),
            CapabilityLine(label: "Replay history", supported: capabilities.canReplay, key: "replay"),
            CapabilityLine(label: "Manage members", supported: capabilities.canManageMembers, key: "manage-members"),
        ]
    }
}