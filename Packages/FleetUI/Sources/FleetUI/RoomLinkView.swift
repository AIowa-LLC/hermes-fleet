import SwiftUI
import Observation
import FleetCore

/// TRUE BOTS MODE slice 5 (D19) — RoomLink view model: feature negotiation,
/// grants (invite with TTL), route registration/revoke, replication/replay,
/// promotion prerequisites + explicit confirmation.
///
/// Honesty rules (binding):
/// - Unsupported gateway → honest unsupported state with the gateway's own
///   reason; NEVER a fake cross-machine surface.
/// - `groups.promote` fires with confirm:true ONLY after the typed
///   confirmation naming the previous authority; a stale replica blocks
///   promotion (fork hazard) with replay offered instead.
/// - The iPhone is foreground-sockets only: no copy claims background
///   couriering (persistent_process is the GATEWAY's truth about itself).
@MainActor
@Observable
public final class RoomLinkViewModel {

    // MARK: Observable state

    public private(set) var negotiation: RoomLinkNegotiation?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var notice: String?
    /// Honest unsupported-state explanation (nil when supported).
    public var unsupportedExplanation: String? {
        guard let negotiation else { return nil }
        guard negotiation.enabled else {
            return negotiation.disabledReason?.explanation
                ?? "This gateway can't link rooms across machines."
        }
        return nil
    }

    // Invite flow
    public private(set) var activeGrant: RoomLinkGrant?
    public private(set) var ttlSeconds: Double = 3600
    public private(set) var isInviting = false

    // Routes
    public private(set) var routes: [RoomPeerRoute] = []

    // Replication / promotion
    public private(set) var replica: RoomReplicaState?
    public private(set) var promotionReadiness: RoomPromotionReadiness = .unknown
    public private(set) var isMutating = false
    /// Test observability: writes attempted through the seam.
    public private(set) var attemptedWriteCount = 0

    // FOS-8 (SPEC §9 Takeover) recovery state:
    /// The operator's explicit assertion that the old writer is fenced.
    /// Promotion is refused (client-side, before the wire) until this is
    /// set AND re-verified against fresh state — Fleet cannot verify
    /// infrastructure fencing itself.
    public var operatorAssertedFencing = false
    /// Lineage from the last observed replica state (the EXACT observed
    /// authorityGatewayID/epoch — demote must use these, never guessed).
    public private(set) var observedLineage: (gatewayID: String, epoch: Int)?
    /// The receipt of the last successful promotion, verbatim.
    public private(set) var lastPromotionReceipt: RoomPromotionReceipt?
    /// Readback after the last promote/demote: the refreshed replica state
    /// (proves both sides' truth after the operation).
    public private(set) var recoveryReadback: RoomReplicaState?

    // MARK: Dependencies

    private let room: FleetRoom
    private let commands: (any RoomLinkCommanding)?

    public init(room: FleetRoom, commands: (any RoomLinkCommanding)? = nil) {
        self.room = room
        self.commands = commands
    }

    // MARK: Lifecycle

    public func start() async {
        await refresh()
    }

    public func refresh() async {
        errorMessage = nil
        guard let commands else {
            errorMessage = "No room connection is available on this gateway."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            negotiation = try await commands.negotiate()
            if negotiation?.enabled == true {
                routes = (try? await commands.peerRoutes(roomID: room.id.key)) ?? []
                replica = try? await commands.replicaState(roomID: room.id.key)
                promotionReadiness = RoomPromotionReadiness.evaluate(
                    replica: replica,
                    localAuthorityGatewayID: negotiation?.authorityGatewayID)
                // FOS-8: capture the EXACT observed lineage — controlled
                // demote later uses these exact values (SPEC §9).
                if let replica {
                    observedLineage = (replica.authorityGatewayID, replica.authorityEpoch)
                }
            }
        } catch {
            errorMessage = Self.explain(error)
        }
    }

    // MARK: - Grants (invite with TTL)

    public func setTTL(_ seconds: Double) {
        ttlSeconds = seconds
    }

    @discardableResult
    public func invite() async -> Bool {
        guard let commands, let negotiation, negotiation.enabled else { return false }
        if let validation = RoomLinkGrant.validate(ttlSeconds: ttlSeconds) {
            errorMessage = validation
            return false
        }
        isInviting = true
        defer { isInviting = false }
        attemptedWriteCount += 1
        do {
            activeGrant = try await commands.invite(
                roomID: room.id.key,
                memberID: nil,
                ttlSeconds: ttlSeconds)
            notice = "Grant minted for \(activeGrant?.targetProfile ?? "the target"). It expires \(Self.shortRemaining(activeGrant))."
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.explain(error)
            return false
        }
    }

    @discardableResult
    public func revokeGrant() async -> Bool {
        guard let commands, let grant = activeGrant else { return false }
        isMutating = true
        defer { isMutating = false }
        attemptedWriteCount += 1
        do {
            try await commands.revoke(grant: grant)
            activeGrant = nil
            notice = "Grant revoked."
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.explain(error)
            return false
        }
    }

    // MARK: - Route registration

    @discardableResult
    public func registerPeer() async -> Bool {
        guard let commands, let negotiation, negotiation.enabled,
              let grant = activeGrant else {
            errorMessage = "Invite a grant first, then register the route."
            return false
        }
        // target_url: the endpoint the TARGET advertised at invite time
        // (authoritative), falling back to this gateway's negotiated
        // endpoint when the invite response omitted it.
        guard let url = grant.endpointURL ?? negotiation.endpoint?.url,
              grant.endpointURL != nil || negotiation.endpoint?.available == true else {
            errorMessage = "No RoomLink endpoint is available for this target."
            return false
        }
        isMutating = true
        defer { isMutating = false }
        attemptedWriteCount += 1
        do {
            let route = try await commands.registerPeer(
                roomID: room.id.key,
                memberID: grant.memberID ?? "",
                grant: grant,
                targetURL: url)
            routes = routes.filter { $0.id != route.id } + [route]
            notice = "Linked \(route.targetProfile.isEmpty ? "peer" : route.targetProfile) over \(route.transportSecurity == "tls" ? "TLS" : route.transportSecurity)."
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.explain(error)
            return false
        }
    }

    // MARK: - Replication / replay

    /// Manual replication choreography (defect-2 fix): pull the authority's
    /// real room profile + verbatim log pages and submit each page to
    /// `groups.replicate` — never placeholder metadata. All guards
    /// (lineage continuity, page progress, fail-closed assembly) live in
    /// `RoomReplicator`; failures surface honestly here.
    @discardableResult
    public func replicateNow() async -> Bool {
        guard let commands else { return false }
        isMutating = true
        defer { isMutating = false }
        attemptedWriteCount += 1
        do {
            let source = try await commands.roomReplaySource(roomID: room.id.key)
            let sink = try await commands.replicateSink()
            let outcome = try await RoomReplicator.replicate(
                roomID: room.id.key,
                replica: replica,
                source: source,
                sink: sink)
            notice = outcome.caughtUp
                ? "Replay complete — this copy is caught up (event \(outcome.storedSeq))."
                : "Replayed \(outcome.ingested) events (caught up through \(outcome.storedSeq))."
            replica = try? await commands.replicaState(roomID: room.id.key)
            promotionReadiness = RoomPromotionReadiness.evaluate(
                replica: replica,
                localAuthorityGatewayID: negotiation?.authorityGatewayID)
            if let replica {
                observedLineage = (replica.authorityGatewayID, replica.authorityEpoch)
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.explain(error)
            return false
        }
    }

    // MARK: - Promotion (explicit confirmation)

    /// Promotion executes ONLY with the user's explicit confirmation AND the
    /// operator's fencing assertion (FOS-8, SPEC §9 Takeover). The
    /// confirmation copy names the previous authority (never generic).
    /// "Recheck state immediately before promotion": readiness is
    /// re-evaluated from the CURRENT replica at call time, not the cached
    /// view-model snapshot.
    @discardableResult
    public func promote(confirmed: Bool, operatorAssertedFencing: Bool? = nil) async -> Bool {
        guard let commands else { return false }
        if let operatorAssertedFencing { self.operatorAssertedFencing = operatorAssertedFencing }
        guard confirmed else {
            // Never silently promote: without confirmation the wire rejects
            // with 4118 — surface that honestly instead of firing the RPC.
            errorMessage = Self.unconfirmedPromotionMessage
            return false
        }
        guard self.operatorAssertedFencing else {
            errorMessage = Self.fencingAssertionRequiredMessage
            return false
        }
        // Recheck immediately before promotion (SPEC §9): re-read the
        // replica state and re-evaluate readiness from fresh truth.
        let freshReplica = try? await commands.replicaState(roomID: room.id.key)
        if let freshReplica {
            replica = freshReplica
            observedLineage = (freshReplica.authorityGatewayID, freshReplica.authorityEpoch)
            promotionReadiness = RoomPromotionReadiness.evaluate(
                replica: freshReplica,
                localAuthorityGatewayID: negotiation?.authorityGatewayID)
        }
        guard promotionReadiness.isReady else {
            errorMessage = promotionReadiness.confirmationMessage
            return false
        }
        isMutating = true
        defer { isMutating = false }
        attemptedWriteCount += 1
        do {
            let receipt = try await commands.promote(roomID: room.id.key, confirm: true)
            lastPromotionReceipt = receipt
            notice = "This gateway is now the authority (epoch \(receipt.authorityEpoch)). Previous: \(receipt.previousGatewayID)."
            // Readback (SPEC §9): read BOTH sides after promotion — the
            // refreshed replica state is the post-operation truth.
            recoveryReadback = try? await commands.replicaState(roomID: room.id.key)
            await refresh()
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.explain(error)
            return false
        }
    }

    // MARK: - Controlled demotion (FOS-8, SPEC §9 Takeover)

    /// Controlled demotion using the EXACT observed lineage. The observed
    /// authority (gateway + epoch) is re-read immediately before the call;
    /// demote sends those exact values. Readback refreshes both sides after.
    @discardableResult
    public func demote() async -> Bool {
        guard let commands else { return false }
        // Re-observe the lineage NOW — a stale snapshot must not drive a
        // demotion of an authority that already changed.
        guard let fresh = try? await commands.replicaState(roomID: room.id.key) else {
            errorMessage = Self.demoteWithoutLineageMessage
            return false
        }
        replica = fresh
        observedLineage = (fresh.authorityGatewayID, fresh.authorityEpoch)
        promotionReadiness = RoomPromotionReadiness.evaluate(
            replica: fresh,
            localAuthorityGatewayID: negotiation?.authorityGatewayID)
        isMutating = true
        defer { isMutating = false }
        attemptedWriteCount += 1
        do {
            try await commands.demote(
                roomID: room.id.key,
                observedGatewayID: fresh.authorityGatewayID,
                observedEpoch: fresh.authorityEpoch)
            notice = "Demoted authority \(fresh.authorityGatewayID) (epoch \(fresh.authorityEpoch)) on this room, as observed."
            // Readback (SPEC §9): both sides after demotion.
            recoveryReadback = try? await commands.replicaState(roomID: room.id.key)
            await refresh()
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.explain(error)
            return false
        }
    }

    // MARK: Copy helpers

    /// Static copy for the unconfirmed path — never fabricated from a
    /// synthetic `.ready` value (readiness carries real authority lineage).
    static let unconfirmedPromotionMessage =
        "Taking over a room needs your explicit confirmation that the previous authority can no longer commit — promotion does not fence it, and Fleet cannot verify that for you."

    /// FOS-8 (SPEC §9): the operator fencing-assertion gate copy. Fleet
    /// cannot verify infrastructure fencing — the operator asserts it.
    static let fencingAssertionRequiredMessage =
        "Turn on the operator assertion that the previous authority is fenced before taking over. Fleet cannot verify infrastructure fencing, and a timeout, disconnect, or Stop action is not enough."

    /// FOS-8 (SPEC §9): demotion needs the exact observed lineage.
    static let demoteWithoutLineageMessage =
        "No replica state is available — the exact authority lineage can't be observed, so this room can't be demoted safely right now."

    /// Surfaces the fencing-assertion requirement inline (view-side hook:
    /// the Take over affordance explains instead of opening a dialog).
    public func surfaceFencingAssertionRequired() {
        errorMessage = Self.fencingAssertionRequiredMessage
        notice = nil
    }

    static func shortRemaining(_ grant: RoomLinkGrant?) -> String {
        guard let grant else { return "" }
        let remaining = max(0, grant.expiresAt.timeIntervalSinceNow)
        if remaining > 3600 {
            let hours = Int(remaining / 3600)
            return "in \(hours)h"
        }
        if remaining > 60 {
            return "in \(Int(remaining / 60))m"
        }
        return "in \(Int(remaining))s"
    }

    static func explain(_ error: Error) -> String {
        if let refusal = error as? RoomLinkRegistrationRefusal {
            return refusal.explanation
        }
        return error.localizedDescription
    }
}

// MARK: - Screen

/// RoomLink management panel for one room — honest negotiation state, grant
/// lifecycle with live TTL, routes, replication progress, and the typed
/// promotion confirmation. Fleet visual language (cards, bold headers, mono
/// metadata); no grouped Forms.
public struct RoomLinkView: View {
    @Environment(\.fleetTheme) private var theme
    @State private var viewModel: RoomLinkViewModel
    private let environment: AppEnvironment
    @State private var showingPromotionConfirm = false
    @State private var ttlPresetIndex = 0

    public init(room: FleetRoom, environment: AppEnvironment) {
        self.environment = environment
        _viewModel = State(initialValue: environment.makeRoomLinkViewModel(room: room))
    }

    public var body: some View {
        // FOS-8 (SPEC §9): ONE room-owned inspector. Links and Recovery are
        // child sections of this screen — not four stacked technical cards.
        // The room owns the object; sections carry subject headers.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
                negotiationSection
                if viewModel.unsupportedExplanation == nil {
                    linksSection
                    recoverySection
                }
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.statusDestructive)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fleet.roomlink.error")
                }
                if let notice = viewModel.notice {
                    Text(notice)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fleet.roomlink.notice")
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingMd)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("RoomLink")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
        .refreshable { await viewModel.refresh() }
        // FOS-8 (SPEC §9): the takeover confirmation re-states lineage and
        // the fencing contract. The dialog opens ONLY when the operator
        // assertion is on — without it, the Take over tap surfaces the
        // honest fencing-required explanation inline (no disabled dialog
        // buttons; disabled dialog buttons don't enter the iOS 26 AX tree).
        .confirmationDialog(
            viewModel.promotionReadiness.confirmationTitle ?? "Take over this room?",
            isPresented: $showingPromotionConfirm,
            titleVisibility: .visible
        ) {
            Button("Take over", role: .destructive) {
                Task { await viewModel.promote(confirmed: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.promotionReadiness.confirmationMessage)
        }
        .accessibilityIdentifier("fleet.roomlink.screen")
    }

    /// Section header: subject + symbol, 44pt actionable bar, hidden from
    /// VoiceOver as a standalone stop (the section content carries the
    /// semantics; the header text rides inside each section's first read).
    private struct InspectorSectionHeader: View {
    @Environment(\.fleetTheme) private var theme
        let title: String
        let symbol: String

        var body: some View {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: Negotiation (honest unsupported state)

    @ViewBuilder
    private var negotiationSection: some View {
        // FOS-6/FOS-8: inspector section — plain, no card chrome (SPEC §18).
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                InspectorSectionHeader(title: "Cross-machine link", symbol: "link")
                if viewModel.isLoading && viewModel.negotiation == nil {
                    Text("Checking this gateway…")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                } else if let explanation = viewModel.unsupportedExplanation {
                    Label(explanation, systemImage: "xmark.shield")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.statusDestructive)
                        .accessibilityIdentifier("fleet.roomlink.unsupported")
                } else if let negotiation = viewModel.negotiation {
                    Text(negotiation.transportSummary)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityIdentifier("fleet.roomlink.summary")
                    Text("Authority \(negotiation.authorityGatewayID) · protocol v\(negotiation.protocolVersions.map(String.init).joined(separator: "/"))")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                    if !negotiation.attachmentsSupported {
                        Text("Text only — this gateway can't carry attachments across machines yet.")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        // (card identifier intentionally absent — a card-level identifier
        // overrides every child identifier in the AX tree)
    }

    // MARK: Links section (grant + routes) — FOS-8 child section of the
    // room-owned inspector.

    /// The Links child section: access grant lifecycle + linked peer
    /// routes, one visual group under one subject header.
    @ViewBuilder
    private var linksSection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            InspectorSectionHeader(title: "Links", symbol: "link.badge.plus")
            grantContent
            routesContent
        }
    }

    @ViewBuilder
    private var grantContent: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                Label("Access grant", systemImage: "key")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                if let grant = viewModel.activeGrant {
                    HStack {
                        Text(grant.displayToken)
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                        if grant.isNearExpiry() {
                            Label("expires \(RoomLinkViewModel.shortRemaining(grant))", systemImage: "clock.badge.exclamationmark")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(FleetTheme.statusDestructive)
                        } else {
                            Text("expires \(RoomLinkViewModel.shortRemaining(grant))")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    HStack(spacing: FleetTheme.spacingSm) {
                        Button {
                            Task { await viewModel.registerPeer() }
                        } label: {
                            Label("Link peer", systemImage: "link.badge.plus")
                        }
                        .buttonStyle(.fleetPressable)
                        .accessibilityIdentifier("fleet.roomlink.register")
                        Button(role: .destructive) {
                            Task { await viewModel.revokeGrant() }
                        } label: {
                            Label("Revoke", systemImage: "key.slash")
                        }
                        .buttonStyle(.fleetPressable)
                        .accessibilityIdentifier("fleet.roomlink.revoke")
                    }
                } else {
                    Picker("Grant lifetime", selection: $ttlPresetIndex) {
                        ForEach(RoomLinkGrant.ttlPresets.indices, id: \.self) { index in
                            Text(RoomLinkGrant.ttlPresets[index].label).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("fleet.roomlink.ttl")
                    Button {
                        Task {
                            await viewModel.setTTLAndInvite(RoomLinkGrant.ttlPresets[ttlPresetIndex].seconds)
                        }
                    } label: {
                        Label("Invite peer", systemImage: "person.badge.key")
                    }
                    .buttonStyle(.fleetPressable)
                    .disabled(viewModel.isInviting)
                    .accessibilityIdentifier("fleet.roomlink.invite")
                }
            }
        }

    @ViewBuilder
    private var routesContent: some View {
        // FOS-6/FOS-8: links child section — plain (SPEC §18).
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                Label("Linked peers", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                if viewModel.routes.isEmpty {
                    Text("No peers linked to this room yet.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                } else {
                    ForEach(viewModel.routes) { route in
                        HStack {
                            Image(systemName: route.status == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(route.status == .ready ? FleetTheme.statusOnline : FleetTheme.statusDestructive)
                            Text(route.memberID)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.textPrimary)
                            Text(route.status.rawValue)
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(theme.textSecondary)
                            Spacer()
                            Text(route.transportSecurity)
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("fleet.roomlink.route.\(route.memberID)")
                    }
                }
        }
    }

    // MARK: Recovery section (replication + takeover) — FOS-8

    /// The Recovery child section: replica coverage, EXACT observed lineage
    /// (authorityGatewayID/epoch), the operator fencing-assertion toggle,
    /// explicit takeover, controlled demotion using the exact observed
    /// lineage, and readback both sides after each operation.
    @ViewBuilder
    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            InspectorSectionHeader(title: "Recovery", symbol: "externaldrive.badge.timemachine")

            if let replica = viewModel.replica {
                // Replica coverage (SPEC §9: takeover requires current
                // replica coverage).
                HStack {
                    Text("Replay \(replica.isCaughtUp ? "complete" : "in progress")")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text("event \(replica.lastSeq)/\(replica.latestSeq)")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("fleet.roomlink.replica-progress")
                }
                ProgressView(value: replica.progress)
                    .accessibilityIdentifier("fleet.roomlink.replay-progress")

                // EXACT observed lineage (SPEC §9: "named old/new authorities
                // and epoch") — mono, machine data.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Observed authority")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                    Text("\(replica.authorityGatewayID) · epoch \(replica.authorityEpoch)")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Observed authority \(replica.authorityGatewayID), epoch \(replica.authorityEpoch)")
                .accessibilityIdentifier("fleet.roomlink.observed-lineage")

                // Replay + takeover row.
                HStack(spacing: FleetTheme.spacingSm) {
                    Button {
                        Task { await viewModel.replicateNow() }
                    } label: {
                        Label("Replay now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityIdentifier("fleet.roomlink.replicate")
                    Button {
                        if viewModel.operatorAssertedFencing {
                            showingPromotionConfirm = true
                        } else {
                            // Honest inline refusal — Fleet cannot verify
                            // fencing; the operator must assert it first.
                            viewModel.surfaceFencingAssertionRequired()
                        }
                    } label: {
                        Label("Take over…", systemImage: "crown")
                    }
                    .buttonStyle(.fleetPressable)
                    .disabled(!viewModel.promotionReadiness.isReady)
                    .accessibilityIdentifier("fleet.roomlink.promote")
                }

                if !viewModel.promotionReadiness.isReady {
                    Text(viewModel.promotionReadiness.confirmationMessage)
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fleet.roomlink.promotion-blocked")
                }

                // Operator fencing assertion (SPEC §9 Takeover): a separate,
                // explicit toggle. Promote stays disabled until BOTH the
                // replica is caught up AND the operator has asserted fencing.
                fencingAssertionToggle

                // Last promotion receipt lineage (verbatim).
                if let receipt = viewModel.lastPromotionReceipt {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last takeover")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(theme.textSecondary)
                        Text("\(receipt.authorityGatewayID) · epoch \(receipt.authorityEpoch) · previous \(receipt.previousGatewayID) (epoch \(receipt.previousEpoch))")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(theme.textPrimary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Last takeover: authority \(receipt.authorityGatewayID), epoch \(receipt.authorityEpoch), previous \(receipt.previousGatewayID), epoch \(receipt.previousEpoch)")
                    .accessibilityIdentifier("fleet.roomlink.last-promotion")
                }

                // Readback after promote/demote: the refreshed replica
                // truth, both sides stated.
                if let readback = viewModel.recoveryReadback {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Readback after last recovery step")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(theme.textSecondary)
                        Text("authority \(readback.authorityGatewayID) · epoch \(readback.authorityEpoch) · event \(readback.lastSeq)/\(readback.latestSeq)")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(theme.textPrimary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Readback: authority \(readback.authorityGatewayID), epoch \(readback.authorityEpoch), event \(readback.lastSeq) of \(readback.latestSeq)")
                    .accessibilityIdentifier("fleet.roomlink.readback")
                }

                // Controlled demotion using the exact observed lineage.
                Button(role: .destructive) {
                    Task { await viewModel.demote() }
                } label: {
                    Label(
                        "Demote \(viewModel.observedLineage.map { "\($0.gatewayID) (epoch \($0.epoch))" } ?? "observed authority")",
                        systemImage: "arrow.down.circle")
                }
                .buttonStyle(.fleetPressable)
                .disabled(viewModel.isMutating)
                .accessibilityIdentifier("fleet.roomlink.demote")
            } else {
                Text("No replay copy on this gateway yet.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    /// The operator fencing-assertion toggle (SPEC §9): Fleet cannot verify
    /// infrastructure fencing; the operator asserts the old writer is
    /// fenced. Copy explains exactly what a timeout/disconnect/Stop is NOT
    /// sufficient for.
    private var fencingAssertionToggle: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            Toggle(isOn: Binding(
                get: { viewModel.operatorAssertedFencing },
                set: { viewModel.operatorAssertedFencing = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("I confirm the previous authority is fenced")
                        .font(FleetTheme.secondaryFont)
                    Text("Fleet can't verify that the old writer stopped. A timeout, disconnect, or Stop action is not enough — confirm it can no longer commit before taking over.")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("fleet.roomlink.fencing-toggle")
        }
    }

}
extension RoomLinkViewModel {
    func setTTLAndInvite(_ seconds: Double) async {
        setTTL(seconds)
        await invite()
    }
}
