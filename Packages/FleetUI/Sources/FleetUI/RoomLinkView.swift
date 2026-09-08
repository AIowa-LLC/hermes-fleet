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
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.explain(error)
            return false
        }
    }

    // MARK: - Promotion (explicit confirmation)

    /// Promotion executes ONLY with the user's explicit confirmation. The
    /// confirmation copy names the previous authority (never generic).
    @discardableResult
    public func promote(confirmed: Bool) async -> Bool {
        guard let commands else { return false }
        guard confirmed else {
            // Never silently promote: without confirmation the wire rejects
            // with 4118 — surface that honestly instead of firing the RPC.
            errorMessage = Self.unconfirmedPromotionMessage
            return false
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
            notice = "This gateway is now the authority (epoch \(receipt.authorityEpoch)). Previous: \(receipt.previousGatewayID)."
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
    @State private var viewModel: RoomLinkViewModel
    private let environment: AppEnvironment
    @State private var showingPromotionConfirm = false
    @State private var ttlPresetIndex = 0

    public init(room: FleetRoom, environment: AppEnvironment) {
        self.environment = environment
        _viewModel = State(initialValue: environment.makeRoomLinkViewModel(room: room))
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                negotiationCard
                if viewModel.unsupportedExplanation == nil {
                    grantCard
                    routesCard
                    replicationCard
                }
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.statusDegraded)
                        .accessibilityIdentifier("fleet.roomlink.error")
                }
                if let notice = viewModel.notice {
                    Text(notice)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .accessibilityIdentifier("fleet.roomlink.notice")
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingMd)
        }
        .background(FleetTheme.background.ignoresSafeArea())
        .navigationTitle("RoomLink")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
        .refreshable { await viewModel.refresh() }
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

    // MARK: Negotiation (honest unsupported state)

    @ViewBuilder
    private var negotiationCard: some View {
        // FOS-6: inspector section — plain, no card chrome (SPEC §18).
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                Label("Cross-machine link", systemImage: "link")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(FleetTheme.textPrimary)
                if viewModel.isLoading && viewModel.negotiation == nil {
                    Text("Checking this gateway…")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                } else if let explanation = viewModel.unsupportedExplanation {
                    Label(explanation, systemImage: "xmark.shield")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.statusDegraded)
                        .accessibilityIdentifier("fleet.roomlink.unsupported")
                } else if let negotiation = viewModel.negotiation {
                    Text(negotiation.transportSummary)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textPrimary)
                        .accessibilityIdentifier("fleet.roomlink.summary")
                    Text("Authority \(negotiation.authorityGatewayID) · protocol v\(negotiation.protocolVersions.map(String.init).joined(separator: "/"))")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                    if !negotiation.attachmentsSupported {
                        Text("Text only — this gateway can't carry attachments across machines yet.")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                    }
                }
            }
        // (card identifier intentionally absent — a card-level identifier
        // overrides every child identifier in the AX tree)
    }

    // MARK: Grant card (invite + TTL + revoke)

    @ViewBuilder
    private var grantCard: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                Label("Access grant", systemImage: "key")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                if let grant = viewModel.activeGrant {
                    HStack {
                        Text(grant.displayToken)
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                        Spacer()
                        if grant.isNearExpiry() {
                            Label("expires \(RoomLinkViewModel.shortRemaining(grant))", systemImage: "clock.badge.exclamationmark")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(FleetTheme.statusDegraded)
                        } else {
                            Text("expires \(RoomLinkViewModel.shortRemaining(grant))")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(FleetTheme.textSecondary)
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
        // overrides every child identifier in the AX tree)
    }

    // MARK: Routes

    @ViewBuilder
    private var routesCard: some View {
        // FOS-6: inspector section — plain (SPEC §18).
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                Label("Linked peers", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                if viewModel.routes.isEmpty {
                    Text("No peers linked to this room yet.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                } else {
                    ForEach(viewModel.routes) { route in
                        HStack {
                            Image(systemName: route.status == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(route.status == .ready ? FleetTheme.statusOnline : FleetTheme.statusDegraded)
                            Text(route.memberID)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(FleetTheme.textPrimary)
                            Text(route.status.rawValue)
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(FleetTheme.textSecondary)
                            Spacer()
                            Text(route.transportSecurity)
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(FleetTheme.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("fleet.roomlink.route.\(route.memberID)")
                    }
                }
            }
        // (see slice-5 lessons)
    }

    // MARK: Replication / promotion

    @ViewBuilder
    private var replicationCard: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                Label("Replay & takeover", systemImage: "externaldrive.badge.timemachine")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                if let replica = viewModel.replica {
                    HStack {
                        Text("Replay \(replica.isCaughtUp ? "complete" : "in progress")")
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(FleetTheme.textPrimary)
                        Spacer()
                        Text("event \(replica.lastSeq)/\(replica.latestSeq)")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                            .accessibilityIdentifier("fleet.roomlink.replica-progress")
                    }
                    ProgressView(value: replica.progress)
                        .accessibilityIdentifier("fleet.roomlink.replay-progress")
                    HStack(spacing: FleetTheme.spacingSm) {
                        Button {
                            Task { await viewModel.replicateNow() }
                        } label: {
                            Label("Replay now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.fleetPressable)
                        .accessibilityIdentifier("fleet.roomlink.replicate")
                        Button {
                            showingPromotionConfirm = true
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
                            .foregroundStyle(FleetTheme.textSecondary)
                            .accessibilityIdentifier("fleet.roomlink.promotion-blocked")
                    }
                } else {
                    Text("No replay copy on this gateway yet.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                }
            }
        }
        // (see slice-5 lessons)
    }
}

extension RoomLinkViewModel {
    func setTTLAndInvite(_ seconds: Double) async {
        setTTL(seconds)
        await invite()
    }
}
