import SwiftUI
import FleetCore

// Refinement Phase 2 — the top of Fleet Home tells the fleet story: every
// machine with the agents it hosts (who is working right now), then the two
// places that need the user, the approvals Inbox and the Groups where agents
// talk to each other.
//
// Composition only: every value is a pure read of state Home already holds
// (gateways, connection states, the roster snapshot and its last-known
// cache, rooms the app already synced, the inbox store). No networking and
// no new data plumbing (SPEC §17 cost contract). The truth rules carry over:
// an unknown count renders as unknown, never as zero.

/// Status tone for one machine. Offline/unknown stay neutral — no alarm
/// tint (SPEC §14 waiting/offline/unknown rows).
enum FleetMachineTone: Equatable, Sendable {
    case connected
    case connecting
    case needsYou
    case degraded
    case neutral

    var color: Color {
        switch self {
        case .connected: FleetTheme.statusOnline
        case .connecting: FleetTheme.statusExecuting
        case .needsYou: FleetTheme.statusNeedsIntervention
        case .degraded: FleetTheme.statusDegraded
        case .neutral: FleetTheme.statusNeutral
        }
    }
}

/// One machine (gateway) on the fleet strip.
struct FleetMachineSummary: Identifiable {
    let id: GatewayID
    let name: String
    let stateLabel: String
    let tone: FleetMachineTone
    /// Known Bots: the live roster when loaded, else the last-known cache.
    let bots: [FleetBot]
    /// nil when the roster has not answered for this machine (unknown).
    let knownBotCount: Int?
    let isLastKnown: Bool

    var workingBots: [FleetBot] { bots.filter(FleetMachineSummary.isWorking) }

    static func isWorking(_ bot: FleetBot) -> Bool {
        bot.activity == .working || bot.activity == .thinking || bot.activity == .usingTool
    }

    /// "2 working · 5 Bots", "5 Bots · last known", "Bots unknown".
    var detail: String {
        guard let knownBotCount else { return "Bots unknown" }
        if knownBotCount == 0 { return "No Bots reported" }
        let noun = knownBotCount == 1 ? "Bot" : "Bots"
        var parts: [String] = []
        let working = workingBots.count
        if working > 0, !isLastKnown { parts.append("\(working) working") }
        parts.append("\(knownBotCount) \(noun)")
        if isLastKnown { parts.append("last known") }
        return parts.joined(separator: " · ")
    }

    var accessibilityLabel: String { "\(name), \(stateLabel), \(detail)" }
}

// MARK: - Fleet strip

/// "Your fleet": one card per machine, swiping horizontally. Each card shows
/// the machine's state and the faces of the agents it hosts; agents doing
/// work right now wear the executing ring.
struct FleetMachineStrip: View {
    @Environment(\.fleetTheme) private var theme
    let machines: [FleetMachineSummary]
    let management: BotManagementController

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            Text("Your fleet")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("fleet.dashboard.fleet.header")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: FleetTheme.spacingMd) {
                    ForEach(machines) { machine in
                        FleetMachineCard(machine: machine, management: management)
                    }
                }
                // Room for the card borders at the scroll edges.
                .padding(.vertical, 1)
            }
            .scrollClipDisabled()
        }
    }
}

struct FleetMachineCard: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ScaledMetric(relativeTo: .body) private var avatarSide: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 176
    let machine: FleetMachineSummary
    let management: BotManagementController

    /// At most four faces; the rest collapse into "+N".
    private static let maxFaces = 4

    /// Working agents first so the faces lead with who is busy.
    private var faces: [FleetBot] {
        let working = machine.isLastKnown ? [] : machine.workingBots
        let idle = machine.bots.filter { bot in !working.contains(where: { $0.route == bot.route }) }
        return Array((working + idle).prefix(Self.maxFaces))
    }

    var body: some View {
        NavigationLink(value: FleetScreen.gatewayDetail(machine.id)) {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(machine.tone.color)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(machine.stateLabel)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Text(machine.name)
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                faceRow
                Text(machine.detail)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(FleetTheme.spacingMd)
            .frame(width: cardWidth, alignment: .leading)
            .background(
                colorSchemeContrast == .increased ? theme.surfaceIncreased : theme.surface,
                in: RoundedRectangle(cornerRadius: FleetTheme.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FleetTheme.radiusCard, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: colorSchemeContrast == .increased ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: FleetTheme.radiusCard, style: .continuous))
        }
        .buttonStyle(.fleetPressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(machine.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("fleet.dashboard.machine.\(machine.id.rawValue)")
    }

    @ViewBuilder
    private var faceRow: some View {
        if faces.isEmpty {
            // Keeps every card the same height whether or not Bots are known.
            Color.clear.frame(height: avatarSide)
        } else {
            HStack(spacing: -avatarSide * 0.28) {
                ForEach(faces, id: \.route) { bot in
                    FleetMachineFace(
                        bot: bot,
                        management: management,
                        side: avatarSide,
                        isWorking: !machine.isLastKnown && FleetMachineSummary.isWorking(bot))
                }
                let overflow = machine.bots.count - faces.count
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                        .frame(minWidth: avatarSide, minHeight: avatarSide)
                        .background(theme.surfaceElevated, in: Circle())
                        .overlay(Circle().strokeBorder(theme.surface, lineWidth: 2))
                }
            }
        }
    }
}

/// A Bot face sized for the strip. A working agent wears the executing ring
/// (color is reinforced by the card's "N working" text, never the only cue).
private struct FleetMachineFace: View {
    @Environment(\.fleetTheme) private var theme
    let bot: FleetBot
    let management: BotManagementController
    let side: CGFloat
    let isWorking: Bool

    var body: some View {
        BotAvatar(bot: bot, management: management)
            .scaleEffect(side / BotAvatar.side)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.34, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: side * 0.34, style: .continuous)
                    .strokeBorder(isWorking ? FleetTheme.statusExecuting : theme.surface,
                                  lineWidth: isWorking ? 2 : 1.5))
    }
}

// MARK: - Inbox + Groups cards

/// The two destinations that need the user, side by side (stacked at
/// accessibility sizes): approvals waiting in the Inbox, and the Groups where
/// agents talk to each other.
struct FleetHubCards: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let environment: AppEnvironment
    let onOpenGroups: () -> Void

    var body: some View {
        // Room reads reconcile the whole union on access — read it once.
        let rooms = environment.allRooms.filter { !$0.isDeleted }
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: FleetTheme.spacingMd))
            : AnyLayout(HStackLayout(alignment: .top, spacing: FleetTheme.spacingMd))
        layout {
            FleetInboxHubCard(items: environment.inbox.items)
            FleetGroupsHubCard(rooms: rooms, onOpen: onOpenGroups)
        }
    }
}

/// Pure presentation for the hub cards, testable without rendering.
enum FleetHubPresentation {
    /// The most recently active room and its last line, if any.
    static func latestRoomLine(_ rooms: [FleetRoom]) -> (room: FleetRoom, line: String?)? {
        let ranked = rooms.max { lhs, rhs in
            (lhs.recentLog.last?.at ?? 0) < (rhs.recentLog.last?.at ?? 0)
        }
        guard let room = ranked else { return nil }
        guard let message = room.recentLog.last else { return (room, nil) }
        let text = SessionPreviewText.humanReadable(message.text)
        guard !text.isEmpty else { return (room, nil) }
        let speaker = message.from.kind == .user ? "You" : message.from.name
        return (room, "\(speaker): \(text)")
    }

    static func groupsCountLabel(_ count: Int) -> String {
        count == 1 ? "1 group" : "\(count) groups"
    }
}

private struct FleetHubCardChrome<Content: View>: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(FleetTheme.spacingMd)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(
                colorSchemeContrast == .increased ? theme.surfaceIncreased : theme.surface,
                in: RoundedRectangle(cornerRadius: FleetTheme.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FleetTheme.radiusCard, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: colorSchemeContrast == .increased ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: FleetTheme.radiusCard, style: .continuous))
    }
}

private struct FleetHubCardHeader: View {
    @Environment(\.fleetTheme) private var theme
    let title: String
    let systemImage: String
    let badge: Int

    var body: some View {
        HStack(spacing: FleetTheme.spacingSm) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(theme.highlight)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 0)
            if badge > 0 {
                // Explicit ink derived from the fill (blank-pill bug class).
                Text("\(badge)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.onHighlight)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(theme.highlight, in: Capsule())
            }
        }
    }
}

struct FleetInboxHubCard: View {
    @Environment(\.fleetTheme) private var theme
    let items: [InboxItem]

    var body: some View {
        let pending = FleetInboxPresentation.sections(items).pending
        NavigationLink(value: FleetScreen.inbox) {
            FleetHubCardChrome {
                VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    FleetHubCardHeader(title: "Inbox", systemImage: "tray.full", badge: pending.count)
                    if let latest = pending.first {
                        Text(FleetHomeAttention.rowTitle(latest))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Text(FleetInboxPresentation.agentLine(latest))
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    } else {
                        Text("No approvals waiting")
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
        .buttonStyle(.fleetPressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pending.isEmpty
            ? "Inbox, no approvals waiting"
            : "Inbox, \(pending.count) waiting, latest \(FleetHomeAttention.rowTitle(pending[0]))")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("fleet.dashboard.hub.inbox")
    }
}

struct FleetGroupsHubCard: View {
    @Environment(\.fleetTheme) private var theme
    let rooms: [FleetRoom]
    let onOpen: () -> Void

    var body: some View {
        let latest = FleetHubPresentation.latestRoomLine(rooms)
        Button(action: onOpen) {
            FleetHubCardChrome {
                VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    FleetHubCardHeader(title: "Groups", systemImage: "person.3", badge: 0)
                    if let latest {
                        Text(latest.room.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Text(latest.line ?? FleetHubPresentation.groupsCountLabel(rooms.count))
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    } else {
                        Text("Agents talking together show up here")
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .buttonStyle(.fleetPressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(latest.map {
            "Groups, \(FleetHubPresentation.groupsCountLabel(rooms.count)), latest \($0.room.name)"
        } ?? "Groups, none yet")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("fleet.dashboard.hub.groups")
    }
}
