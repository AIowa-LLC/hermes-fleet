import SwiftUI
import FleetCore

/// Live Ops v1 — Operation Detail: the showcase screen pushed from Home's
/// Live Operations section (or a Needs You "Waiting for you" row). Shows the
/// identity header, current activity, the reconstructed swarm tree, a
/// "live since you opened" timeline, and the attached-session controls.
///
/// This view is its own Live Ops poll context (`.detail(operation.id)`) —
/// registering it tightens the shared fleet-wide poll loop to ~2s cadence
/// while any detail screen is open, and it is the ONLY surface that
/// accumulates a timeline for this operation (dropped on disappear).
public struct LiveOperationDetailView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let environment: AppEnvironment
    private let operationID: LiveOperationID

    @State private var now = Date()
    @State private var steerText = ""
    @State private var steeringSubagentID: String?
    @State private var childActionMessage: String?

    public init(environment: AppEnvironment, operation: LiveOperation) {
        self.environment = environment
        self.operationID = operation.id
    }

    /// Always reads the LIVE operation from the store's current snapshot
    /// (never the value captured at push time) so the whole screen updates
    /// as refreshes land, including a status flip mid-visit.
    private var operation: LiveOperation? {
        environment.liveOps.snapshot?.allOperations.first { $0.id == operationID }
    }

    private var isAttached: Bool { environment.liveOps.attachedOperations.contains(operationID) }
    private var timeline: [LiveOpsStore.OperationTimelineEntry] { environment.liveOps.timelines[operationID] ?? [] }

    public var body: some View {
        ScrollView {
            if let operation {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXl) {
                    identityHeader(operation)
                    currentActivity(operation)
                    swarmSection(operation)
                    timelineSection
                    controlsSection(operation)
                }
                .padding(.horizontal, FleetTheme.spacingLg)
                .padding(.vertical, FleetTheme.spacingXl)
            } else {
                VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                    Text("This operation is no longer reporting.")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("It may have finished, or its gateway went offline.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(FleetTheme.spacingLg)
                .accessibilityIdentifier("fleet.liveOpsDetail.gone")
            }
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Operation")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("fleet.liveOpsDetail")
        .task {
            environment.liveOps.beginObserving(.detail(operationID))
            defer { environment.liveOps.endObserving(.detail(operationID)) }
            if let operation { await environment.liveOps.verifyAttachment(operation) }
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: Identity header

    private func identityHeader(_ operation: LiveOperation) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Text(operation.title.isEmpty ? "Untitled session" : operation.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("fleet.liveOpsDetail.title")
            HStack(spacing: FleetTheme.spacingSm) {
                Text(environment.gateway(for: operation.id.gatewayID)?.displayName ?? operation.id.gatewayID.rawValue)
                if !operation.model.isEmpty {
                    Text("·").foregroundStyle(theme.textMuted)
                    Text(operation.model)
                }
                Text("·").foregroundStyle(theme.textMuted)
                Text(FleetDashboardFormatting.relativeTime(from: operation.startedAt, since: now))
            }
            .font(FleetTheme.secondaryFont)
            .foregroundStyle(theme.textSecondary)
            statusRow(operation)
        }
    }

    private func statusRow(_ operation: LiveOperation) -> some View {
        let stale = environment.liveOps.isStale(operation)
        let (label, color): (String, Color) = {
            if stale { return ("Stale", FleetTheme.statusNeutral) }
            switch operation.status {
            case .working: return ("Working", FleetTheme.statusExecuting)
            case .starting: return ("Starting", FleetTheme.statusExecuting)
            case .waiting: return ("Waiting", FleetTheme.statusNeedsIntervention)
            case .idle: return ("Idle", FleetTheme.statusNeutral)
            case .unknown: return ("Unknown", FleetTheme.statusNeutral)
            }
        }()
        return Text(label)
            .font(FleetTheme.monoCaptionFont)
            .foregroundStyle(color)
            .padding(.horizontal, FleetTheme.spacingSm)
            .padding(.vertical, 2)
            .background(FleetTheme.statusPillTint(color), in: Capsule())
            .accessibilityIdentifier("fleet.liveOpsDetail.status")
    }

    // MARK: Current activity

    @ViewBuilder
    private func currentActivity(_ operation: LiveOperation) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Text("Current Activity")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
            if !operation.preview.isEmpty {
                Text(operation.preview)
                    .font(.body)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityIdentifier("fleet.liveOpsDetail.activity")
            } else {
                Text("No recent activity preview from this gateway.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    // MARK: Swarm

    @ViewBuilder
    private func swarmSection(_ operation: LiveOperation) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Text("Swarm")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
            if let tree = operation.swarmTree {
                if tree.isEmpty {
                    Text("No subagents right now.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                        ForEach(tree) { node in
                            swarmNodeView(node, depth: 0, operation: operation)
                        }
                    }
                }
            } else {
                Text("Subagent count is not available from this gateway.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.liveOpsDetail.swarm.unknown")
            }
        }
    }

    /// Type-erased: this view recurses into itself for `node.children`, and
    /// a recursive function cannot return `some View` (the opaque type would
    /// be defined in terms of itself).
    private func swarmNodeView(_ node: LiveOpsSwarmNode, depth: Int, operation: LiveOperation) -> AnyView {
        AnyView(swarmNodeContent(node, depth: depth, operation: operation))
    }

    private func swarmNodeContent(_ node: LiveOpsSwarmNode, depth: Int, operation: LiveOperation) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            HStack(alignment: .top, spacing: FleetTheme.spacingSm) {
                if depth > 0 {
                    // Connector guide: a simple indentation + tick mark reads
                    // clearly at every Dynamic Type size without a bespoke
                    // canvas drawing.
                    Text(String(repeating: "  ", count: depth) + "└─")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textMuted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.subagent.goal.isEmpty ? node.subagent.subagentID : node.subagent.goal)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                    Text(swarmNodeMeta(node.subagent))
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if isAttached {
                    Menu {
                        Button("Steer…") { steeringSubagentID = node.subagent.subagentID }
                        Button("Stop", role: .destructive) {
                            Task {
                                let result = await environment.liveOps.interruptChild(
                                    subagentID: node.subagent.subagentID, operation: operation)
                                switch result {
                                case .success(let found):
                                    childActionMessage = found ? "Interrupt sent" : "Subagent already finished"
                                case .failure(let error):
                                    childActionMessage = error.errorDescription
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Subagent controls")
                }
            }
            ForEach(node.children) { child in
                swarmNodeView(child, depth: depth + 1, operation: operation)
            }
        }
        .accessibilityIdentifier("fleet.liveOpsDetail.swarm.node.\(sanitized(node.subagent.subagentID))")
    }

    private func swarmNodeMeta(_ subagent: LiveOpsSubagent) -> String {
        var parts = [subagent.status]
        if let model = subagent.model, !model.isEmpty { parts.append(model) }
        if let lastTool = subagent.lastTool, !lastTool.isEmpty {
            parts.append("\(lastTool) · \(subagent.toolCount) tools")
        } else {
            parts.append("\(subagent.toolCount) tools")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Timeline

    @ViewBuilder
    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Text("Live Since You Opened")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
            if timeline.isEmpty {
                Text("No changes observed yet — this updates as the operation runs.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.liveOpsDetail.timeline.empty")
            } else {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                    ForEach(timeline.reversed()) { entry in
                        HStack(alignment: .top, spacing: FleetTheme.spacingSm) {
                            Text(FleetDashboardFormatting.relativeTime(from: entry.at, since: now))
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(theme.textMuted)
                            Text(entry.text)
                                .font(FleetTheme.secondaryFont)
                                .foregroundStyle(theme.textPrimary)
                        }
                    }
                }
                .accessibilityIdentifier("fleet.liveOpsDetail.timeline")
            }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func controlsSection(_ operation: LiveOperation) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            Text("Controls")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
            let route = environment.route(forLiveOperationSessionKey: operation.sessionKey, gatewayID: operation.id.gatewayID)
            if let route {
                NavigationLink {
                    conversationDestination(route: route, sessionID: operation.sessionKey)
                } label: {
                    Label("Open Chat", systemImage: "message")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("fleet.liveOpsDetail.openChat")

                Button(role: .destructive) {
                    Task {
                        if let session = environment.conversationSession(for: operation.id.gatewayID) {
                            _ = try? await session.conversation.interrupt(sessionID: operation.sessionKey)
                        }
                    }
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("fleet.liveOpsDetail.stop")
            } else {
                Text("This session isn't open on this phone yet — use Open Chat to attach and control it.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
            }
            if !isAttached {
                Text("Open the chat to control subagents")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.liveOpsDetail.notAttached")
            }
            if let childActionMessage {
                Text(childActionMessage)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .sheet(item: Binding(
            get: { steeringSubagentID.map { SteerTarget(subagentID: $0) } },
            set: { steeringSubagentID = $0?.subagentID }
        )) { target in
            steerSheet(target: target, operation: operation)
        }
    }

    private struct SteerTarget: Identifiable { let subagentID: String; var id: String { subagentID } }

    private func steerSheet(target: SteerTarget, operation: LiveOperation) -> some View {
        NavigationStack {
            Form {
                TextField("Message to subagent", text: $steerText, axis: .vertical)
            }
            .navigationTitle("Steer Subagent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { steeringSubagentID = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let text = steerText
                        steerText = ""
                        let subagentID = target.subagentID
                        steeringSubagentID = nil
                        Task {
                            let result = await environment.liveOps.steer(
                                subagentID: subagentID, operation: operation, text: text)
                            switch result {
                            case .success(.queued): childActionMessage = "Queued"
                            case .success(.rejected): childActionMessage = "Rejected by gateway"
                            case .failure(let error): childActionMessage = error.errorDescription
                            }
                        }
                    }
                }
            }
        }
    }

    private func conversationDestination(route: Route, sessionID: String) -> some View {
        ConversationView(environment: environment, route: route, sessionID: sessionID)
    }

    private func sanitized(_ id: String) -> String {
        id.replacingOccurrences(of: "|", with: ".")
    }
}
