import Foundation
import Observation
import FleetCore

/// What the pairing flow needs from the app that owns the gateway registry.
/// `AppEnvironment` conforms; tests use a recording double.
@MainActor
public protocol PairingHosting: AnyObject {
    /// A gateway already in Fleet that is the same as the one being paired: the same stable
    /// installation id, or (for a gateway added by hand) the same address.
    func existingGateway(forPairedInstance instanceID: String, origin: URL) -> FleetGateway?
    /// Register the paired gateway, pin its validated key, and save its device credential in
    /// the Keychain. Throws if ANY part fails; the host leaves nothing half-added.
    func addPairedGateway(_ grant: PairingGrant) async throws -> FleetGateway
    /// Best-effort: tell the gateway to revoke a credential this phone just received but could
    /// not keep. Never throws.
    func revokeUnsavedDevice(_ grant: PairingGrant) async -> PairingRevocationOutcome
    /// Name shown to the gateway owner in their device list.
    var pairingDeviceName: String { get }
    /// Hardware model identifier shown next to the name when the owner approves (e.g. `iPhone17,1`).
    var pairingDeviceModel: String { get }
}

public extension PairingHosting {
    var pairingDeviceModel: String { "iPhone" }
}

/// The Add to Fleet flow, end to end:
///
///     receive link ─▶ preview (no side effect) ─▶ person confirms ─▶ redeem ─▶ save ─▶ done        (v1 link)
///     receive link ─▶ preview ─▶ person confirms ─▶ request ─▶ owner approves the code ─▶ save    (v2 link)
///
/// A v2 link never redeems on its own: confirming creates a pending request that the owner
/// approves by its match code, and the phone polls (with a random client secret only it holds)
/// until the credential is handed over, the request is denied, or it expires.
///
/// Guarantees:
/// - Receiving or previewing a link consumes nothing and approves nothing; only `confirm()`
///   redeems, and only from the confirming state.
/// - `cancel()` before `confirm()` leaves the invitation fully usable.
/// - The link (and its secret) is kept in memory only, is never written to disk, and is
///   dropped on completion, cancel, or any terminal failure.
/// - If a credential was received but cannot be saved, it is revoked on the gateway and the
///   phone reports that nothing was added.
/// - A gateway already in Fleet (same installation id or same address) is detected BEFORE
///   redeeming, so a duplicate never consumes an invitation.
@MainActor @Observable
public final class PairingCoordinator {
    public enum Phase: Equatable, Sendable {
        /// Nothing in progress.
        case idle
        /// Waiting for the person to paste or scan a link.
        case awaitingLink
        /// Contacting the gateway to show what the invitation offers.
        case previewing(host: String)
        /// Showing the gateway identity and requested access; waiting for an explicit decision.
        case confirming(PairingPreview)
        /// The gateway is already in Fleet; nothing was consumed.
        case alreadyAdded(name: String)
        /// The person approved; exchanging the invitation. Not cancellable (it may already be consumed).
        case redeeming(PairingPreview)
        /// v2: creating the pending request on the gateway.
        case requesting(PairingPreview)
        /// v2: the request exists; the owner has to approve `code` (six digits). Polling.
        case awaitingApproval(code: String, expiresAt: Date)
        /// v2: the owner denied the request.
        case denied
        /// v2: the request ran out of time before the owner approved it.
        case expired
        case completed(name: String)
        case failed(PairingFailure, host: String?)
    }

    /// How the flow was started; decides which surface presents it.
    public enum Entry: Equatable, Sendable {
        /// A link arrived from outside the app (Universal Link / open URL / launch).
        case link
        /// The person chose "Add with Pairing Link" inside Add Gateway.
        case manual
    }

    public private(set) var phase: Phase = .idle
    public private(set) var entry: Entry = .link
    /// Bumps each time a flow starts, so a presenter can key its sheet to one flow.
    public private(set) var flowID = 0

    @ObservationIgnored private let service: (any GatewayPairing)?
    @ObservationIgnored private weak var host: (any PairingHosting)?
    /// Memory-only. Never persisted, logged or placed in an error.
    @ObservationIgnored private var link: PairingInvitationLink?
    @ObservationIgnored private var unsavedGrant: PairingGrant?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void
    /// Memory-only, per pairing session: binds the pending request to this phone. Losing it
    /// (app killed) only lets the request expire. Never persisted, logged or placed in an error.
    @ObservationIgnored private var clientSecret: PairingClientSecret?
    @ObservationIgnored private var confirmedPreview: PairingPreview?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isPollingPaused = false
    /// What Retry repeats after a transient failure.
    @ObservationIgnored private var retryStage: RetryStage = .preview

    private enum RetryStage {
        case preview
        /// The request call failed; the client secret is kept so repeating it is idempotent
        /// (the gateway may already have created it).
        case request(PairingPreview)
    }

    /// The pending approval request while the owner has not decided; nil otherwise.
    public private(set) var pendingRequest: PairingApprovalRequest?
    /// Whether the link being handled carried a TLS key pin (version 2). Decides the wording
    /// of certificate failures; stays valid after a failure drops the link itself.
    public private(set) var linkIsPinned = false
    /// The app's own URL scheme, so `<scheme>://pair#…` links are recognised. Set by the
    /// composition root.
    public var appURLScheme: String?

    public init(
        service: (any GatewayPairing)?,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.service = service
        self.now = now
        self.sleep = sleep
    }

    /// Wire the registry owner (done by `AppEnvironment` right after it is created).
    public func attach(host: any PairingHosting) {
        self.host = host
    }

    /// Whether this build can pair at all.
    public var isAvailable: Bool { service != nil }

    /// Whether a flow is on screen / in progress.
    public var isActive: Bool { phase != .idle }

    /// Whether the person can still back out without any side effect.
    public var canCancel: Bool {
        if case .redeeming = phase { return false }
        return true
    }

    /// The reachability diagnosis for the current failure, when it is one.
    public var diagnosis: PairingDiagnosis? {
        guard case .failed(let failure, let host) = phase else { return nil }
        return PairingDiagnosis.diagnose(failure, host: host, linkIsPinned: linkIsPinned)
    }

    // MARK: Intake

    /// A URL the system delivered (Universal Link or open-URL). Returns whether it is a
    /// pairing link and was taken. A malformed pairing link is still "taken", so the person
    /// gets a clear message instead of nothing.
    @discardableResult
    public func receive(url: URL) -> Bool {
        guard PairingInvitationLink.looksLikePairingLink(url, appURLScheme: appURLScheme) else { return false }
        start(entry: .link, text: url.absoluteString)
        return true
    }

    /// Text the person pasted or a QR code carried.
    @discardableResult
    public func receive(text: String, entry: Entry = .manual) -> Bool {
        start(entry: entry, text: text)
        return true
    }

    /// Open the flow awaiting a pasted/scanned link.
    public func beginManualEntry() {
        guard !isBusy else { return }
        if let grant = unsavedGrant {
            phase = .failed(.rollbackUnconfirmed, host: grant.gateway.origin.host)
            return
        }
        cancelTask()
        resetApprovalState()
        link = nil
        flowID += 1
        entry = .manual
        phase = service == nil ? .failed(.pairingUnavailable, host: nil) : .awaitingLink
    }

    public var canRetry: Bool {
        guard case .failed(let failure, _) = phase else { return false }
        return (Self.allowsRetry(failure, link: link) && link != nil)
            || (failure == .rollbackUnconfirmed && unsavedGrant != nil)
    }

    public var isBusy: Bool {
        switch phase {
        case .previewing, .redeeming, .requesting: return true
        default: return false
        }
    }

    /// Whether trying the same link again can help. A pinned (v2) link also lets the person
    /// try again after a certificate or key problem: nothing secret is sent to a server whose
    /// key does not match the pin, so a retry is harmless.
    private static func allowsRetry(_ failure: PairingFailure, link: PairingInvitationLink?) -> Bool {
        if failure.isRetryable { return true }
        guard link?.pin != nil else { return false }
        return failure == .untrustedCertificate || failure == .identityMismatch
    }

    private func start(entry: Entry, text: String) {
        guard unsavedGrant == nil else {
            phase = .failed(.rollbackUnconfirmed, host: unsavedGrant?.gateway.origin.host)
            return
        }
        // A second delivery of the very same link (the system can report one tap through two
        // callbacks) must not restart a flow already underway.
        if let active = link, let incoming = try? PairingInvitationLink.parse(text, appURLScheme: appURLScheme),
           active.invitationID == incoming.invitationID, active.origin == incoming.origin,
           phase != .idle, !isTerminal {
            return
        }
        // Never abandon a redemption that is in flight.
        if case .redeeming = phase { return }
        cancelTask()
        resetApprovalState()
        flowID += 1
        self.entry = entry
        guard service != nil else {
            link = nil
            phase = .failed(.pairingUnavailable, host: nil)
            return
        }
        do {
            let parsed = try PairingInvitationLink.parse(text, appURLScheme: appURLScheme)
            link = parsed
            linkIsPinned = parsed.pin != nil
            retryStage = .preview
            phase = .previewing(host: parsed.host)
            task = Task { [weak self] in await self?.runPreview() }
        } catch {
            link = nil
            phase = .failed(Self.failure(for: error), host: nil)
        }
    }

    private var isTerminal: Bool {
        switch phase {
        case .completed, .failed, .alreadyAdded, .denied, .expired: return true
        default: return false
        }
    }

    // MARK: Steps

    private func runPreview() async {
        guard let service, let link else { return }
        do {
            let preview = try await service.preview(link)
            guard !Task.isCancelled, self.link == link else { return }
            if let existing = host?.existingGateway(
                forPairedInstance: preview.gateway.instanceID, origin: preview.gateway.origin) {
                self.link = nil   // nothing to redeem; do not keep the secret around
                phase = .alreadyAdded(name: existing.displayName)
                return
            }
            if preview.expiresAt <= now() {
                self.link = nil
                phase = .failed(.expired, host: link.host)
                return
            }
            phase = .confirming(preview)
        } catch {
            guard !Task.isCancelled, self.link == link else { return }
            // Only a failure that trying again can fix keeps the link in memory.
            if !Self.allowsRetry(error, link: link) { self.link = nil }
            phase = .failed(error, host: link.host)
        }
    }

    /// Retry after a retryable failure (offline, rate limited, interrupted preview).
    public func retry() {
        if case .failed(.rollbackUnconfirmed, let hostName) = phase, let grant = unsavedGrant {
            phase = .redeeming(PairingPreview(gateway: grant.gateway, label: "", access: [], expiresAt: now(), tlsFingerprint: grant.tlsFingerprint))
            task = Task { [weak self] in await self?.rollback(grant, hostName: hostName) }
            return
        }
        guard case .failed(let failure, _) = phase, Self.allowsRetry(failure, link: link), let link else { return }
        cancelTask()
        if case .request(let preview) = retryStage, let service {
            phase = .requesting(preview)
            task = Task { [weak self] in await self?.runRequest(link: link, preview: preview, service: service) }
            return
        }
        phase = .previewing(host: link.host)
        task = Task { [weak self] in await self?.runPreview() }
    }

    /// The person approved the shown gateway and access. The only path that redeems.
    public func confirm() {
        guard case .confirming(let preview) = phase, let link, let service else { return }
        if preview.expiresAt <= now() {
            self.link = nil
            phase = .failed(.expired, host: link.host)
            return
        }
        if link.requiresApproval {
            confirmedPreview = preview
            retryStage = .request(preview)
            phase = .requesting(preview)
            task = Task { [weak self] in await self?.runRequest(link: link, preview: preview, service: service) }
            return
        }
        phase = .redeeming(preview)
        task = Task { [weak self] in await self?.runRedeem(link: link, preview: preview, service: service) }
    }

    private func runRedeem(
        link: PairingInvitationLink, preview: PairingPreview, service: any GatewayPairing
    ) async {
        let grant: PairingGrant
        do {
            grant = try await service.redeem(
                link, deviceName: host?.pairingDeviceName ?? "iPhone", expecting: preview)
        } catch {
            // Nothing was consumed if the failure is a pre-send one (offline, key changed);
            // keep the link for those so Retry can start over from the preview.
            finish(.failed(error, host: link.host), keepLink: error.isRetryable ? link : nil)
            return
        }
        await save(grant, hostName: link.host)
    }

    /// Hand a received credential to the registry owner. Shared by direct redemption (v1) and
    /// an approved request (v2): on any failure the credential is revoked and nothing is added.
    private func save(_ grant: PairingGrant, hostName: String) async {
        guard let host else {
            await rollback(grant, hostName: hostName)
            return
        }
        do {
            let gateway = try await host.addPairedGateway(grant)
            finish(.completed(name: gateway.displayName))
        } catch {
            await rollback(grant, hostName: hostName)
        }
    }

    // MARK: Approval (v2)

    private func runRequest(
        link: PairingInvitationLink, preview: PairingPreview, service: any GatewayPairing
    ) async {
        let secret = clientSecret ?? PairingClientSecret.generate()
        clientSecret = secret
        let request: PairingApprovalRequest
        do {
            request = try await service.requestApproval(
                link, deviceName: host?.pairingDeviceName ?? "iPhone",
                deviceModel: host?.pairingDeviceModel ?? "iPhone",
                clientSecret: secret, expecting: preview)
        } catch {
            guard !Task.isCancelled, self.link == link else { return }
            // The request may exist on the gateway already (a lost response): keep the same
            // client secret so repeating the call returns that very request.
            if !Self.allowsRetry(error, link: link) {
                self.link = nil
                clientSecret = nil
            }
            task = nil
            phase = .failed(error, host: link.host)
            return
        }
        guard !Task.isCancelled, self.link == link else { return }
        pendingRequest = request
        task = nil
        isPollingPaused = false
        phase = .awaitingApproval(code: request.matchCode, expiresAt: request.expiresAt)
        startPolling()
    }

    /// Suspend polling (the app left the foreground). The request stays valid on the gateway;
    /// `resumePolling()` picks it up again with the same client secret.
    public func pausePolling() {
        guard case .awaitingApproval = phase else { return }
        isPollingPaused = true
        pollTask?.cancel()
        pollTask = nil
    }

    /// Continue polling after `pausePolling()`. Reports the request as expired when its time
    /// ran out meanwhile.
    public func resumePolling() {
        guard case .awaitingApproval(_, let expiresAt) = phase, isPollingPaused else { return }
        isPollingPaused = false
        if expiresAt <= now() {
            endApproval(.expired)
            return
        }
        startPolling()
    }

    // MARK: Presentation and lifecycle

    /// Screens that present the flow themselves (first-run, the add-server sheet) register here
    /// so the app-level presenter does not also show it. Reference counted.
    public private(set) var inlinePresenters = 0
    public var hasInlinePresenter: Bool { inlinePresenters > 0 }
    public func registerPresenter() { inlinePresenters += 1 }
    public func unregisterPresenter() { inlinePresenters = max(0, inlinePresenters - 1) }

    /// The app left the foreground. A waiting approval is only paused (the request stays valid
    /// on the gateway); an un-confirmed invitation is dropped, as before; a redemption in
    /// flight or a pending cleanup is never abandoned.
    public func appMovedToBackground() {
        switch phase {
        case .awaitingApproval:
            pausePolling()
        case .failed(.rollbackUnconfirmed, _) where canRetry:
            break
        default:
            guard canCancel, isActive else { return }
            cancel()
        }
    }

    /// The app is active again: continue a paused approval.
    public func appBecameActive() {
        resumePolling()
    }

    /// Whether the waiting screen is currently polling.
    public var isPolling: Bool { pollTask != nil }

    private func startPolling() {
        guard pollTask == nil, !isPollingPaused,
              case .awaitingApproval = phase, let request = pendingRequest,
              let secret = clientSecret, let service else { return }
        let flow = flowID
        pollTask = Task { [weak self] in
            await self?.pollLoop(request: request, secret: secret, service: service, flow: flow)
        }
    }

    /// Poll every `pollInterval` (at least one second; five seconds after a transient error),
    /// while this flow is on screen and active. Only the owner's decision, the request's end,
    /// or a non-transient failure stops it.
    private func pollLoop(
        request: PairingApprovalRequest, secret: PairingClientSecret,
        service: any GatewayPairing, flow: Int
    ) async {
        var interval = max(request.pollInterval, Self.minimumPollInterval)
        func isCurrent() -> Bool { !Task.isCancelled && flowID == flow && pendingRequest == request }
        while isCurrent() {
            await sleep(interval)
            guard isCurrent() else { return }
            if request.expiresAt <= now() {
                endApproval(.expired)
                return
            }
            do {
                let status = try await service.pollApproval(request, clientSecret: secret)
                guard isCurrent() else { return }
                switch status {
                case .pending:
                    interval = max(request.pollInterval, Self.minimumPollInterval)
                case .approved(let grant):
                    pollTask = nil
                    pendingRequest = nil
                    clientSecret = nil
                    link = nil
                    phase = .redeeming(confirmedPreview ?? PairingPreview(
                        gateway: grant.gateway, label: "", access: [], expiresAt: now(),
                        tlsFingerprint: grant.tlsFingerprint))
                    await save(grant, hostName: grant.gateway.origin.host ?? "")
                    return
                case .denied:
                    endApproval(.denied)
                    return
                case .expired:
                    endApproval(.expired)
                    return
                case .delivered:
                    // Approved and already collected, but not by a poll this phone still holds
                    // the result of: the credential cannot be handed over again.
                    endApproval(.failed(.alreadyUsed, host: request.gateway.origin.host))
                    return
                }
            } catch {
                guard isCurrent() else { return }
                if Self.isTransient(error) {
                    interval = Self.backoffPollInterval
                } else {
                    endApproval(.failed(error, host: request.gateway.origin.host))
                    return
                }
            }
        }
    }

    static let minimumPollInterval: TimeInterval = 1
    static let backoffPollInterval: TimeInterval = 5

    /// Failures that polling again may outlast (no answer, slow down, a gateway hiccup).
    private static func isTransient(_ failure: PairingFailure) -> Bool {
        failure.isRetryable || failure == .malformedResponse
    }

    private func endApproval(_ terminal: Phase) {
        pollTask?.cancel()
        pollTask = nil
        pendingRequest = nil
        clientSecret = nil
        link = nil
        task = nil
        phase = terminal
    }

    private func resetApprovalState() {
        pollTask?.cancel()
        pollTask = nil
        pendingRequest = nil
        clientSecret = nil
        confirmedPreview = nil
        isPollingPaused = false
    }

    private func rollback(_ grant: PairingGrant, hostName: String?) async {
        let outcome: PairingRevocationOutcome
        if let host { outcome = await host.revokeUnsavedDevice(grant) }
        else if let service {
            outcome = await service.revoke(origin: grant.gateway.origin, credential: grant.credential, expecting: grant.tlsFingerprint)
        } else { outcome = .failed }
        let confirmed = outcome == .revoked || outcome == .alreadyRevoked
        unsavedGrant = confirmed ? nil : grant
        finish(.failed(confirmed ? .couldNotSave : .rollbackUnconfirmed, host: hostName))
    }

    private func finish(_ terminal: Phase, keepLink: PairingInvitationLink? = nil) {
        link = keepLink
        task = nil
        phase = terminal
    }

    // MARK: Leaving

    /// Back out. Before `confirm()` this has no effect on the invitation (it stays usable
    /// until it expires or the owner cancels it). Ignored while redeeming.
    public func cancel() {
        guard canCancel else { return }
        cancelTask()
        resetApprovalState()
        link = nil
        phase = .idle
    }

    /// Dismiss a finished flow (completed, failed, already added).
    public func dismiss() {
        guard canCancel else { return }
        cancel()
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
    }

    // MARK: Mapping

    static func failure(for error: Error) -> PairingFailure {
        switch error as? PairingInvitationLink.ParseError {
        case .insecureScheme, .invalidHost: return .insecureDestination
        case .unsupportedVersion: return .unsupportedLinkVersion
        default: return .malformedLink
        }
    }
}

// MARK: - Wording

/// The words the person reads for each outcome. Plain, specific, and never including a link,
/// secret, or server-supplied text.
public enum PairingCopy {
    public static func title(for failure: PairingFailure) -> String {
        switch failure {
        case .expired: return "This link has expired"
        case .alreadyUsed: return "This link was already used"
        case .cancelled: return "This link was cancelled"
        case .invalidInvitation: return "This link isn't valid"
        case .malformedLink: return "That isn't a pairing link"
        case .unsupportedLinkVersion: return "Update Hermes Fleet"
        case .insecureDestination: return "This link can't be trusted"
        case .unreachable, .hostNotFound, .timedOut, .connectionRefused: return "Can't reach the gateway"
        case .offline: return "This iPhone is offline"
        case .approvalNotSupported: return "Approval isn't available here"
        case .approvalRequired: return "This link needs approval"
        case .invalidRequest: return "This request is no longer valid"
        case .untrustedCertificate: return "Gateway certificate not trusted"
        case .identityMismatch: return "The gateway changed"
        case .pairingUnavailable: return "Pairing isn't available here"
        case .rateLimited: return "Too many attempts"
        case .unsupportedAccess: return "Unsupported access request"
        case .malformedResponse, .serverError: return "The gateway didn't answer correctly"
        case .interrupted: return "Pairing was interrupted"
        case .couldNotSave: return "Couldn't add the gateway"
        case .rollbackUnconfirmed: return "Device cleanup needs attention"
        }
    }

    /// - Parameter linkIsPinned: whether the link carried a TLS key pin (version 2); certificate
    ///   failures then use the diagnosis wording.
    public static func message(for failure: PairingFailure, host: String?, linkIsPinned: Bool = false) -> String {
        if let diagnosis = PairingDiagnosis.diagnose(failure, host: host, linkIsPinned: linkIsPinned) {
            return diagnosis.message
        }
        let where_ = host.map { "“\($0)”" } ?? "the gateway"
        switch failure {
        case .expired:
            return "Pairing links only work for a few minutes. Ask Hermes for a new QR code and scan it again."
        case .alreadyUsed:
            return "A pairing link works once. If you didn't use it, someone else may have — ask for a new link and check the device list on the gateway."
        case .cancelled:
            return "The owner cancelled this link, or it was locked after too many wrong tries. Ask for a new one."
        case .invalidInvitation:
            return "\(where_.capitalizedFirst) doesn't recognise this link. Check that it was copied completely, or ask for a new one."
        case .malformedLink:
            return "Scan the QR code for a genuine Hermes Fleet pairing invitation shown on your host computer."
        case .unsupportedLinkVersion:
            return "This link was made for a newer version of Hermes Fleet. Update the app, then open it again."
        case .insecureDestination:
            return "Pairing links must be https links to a real gateway address. Nothing was contacted."
        case .approvalNotSupported:
            return "\(where_.capitalizedFirst) can't approve a new phone from a link (it may need a newer Hermes Fleet connector). Ask Hermes for a new link."
        case .approvalRequired:
            return "This link has to be approved by the server's owner, and this one can't be. Ask Hermes for a new link with `/fleet pair`."
        case .invalidRequest:
            return "\(where_.capitalizedFirst) no longer recognises this request. Ask Hermes for a new link."
        case .unreachable, .hostNotFound, .timedOut, .connectionRefused, .offline:
            return "This phone couldn't connect to \(where_). A pairing link doesn't create a network path: the gateway must be reachable from this phone (internet, VPN or the same network). Check your connection and try again."
        case .untrustedCertificate:
            return "\(where_.capitalizedFirst) presented a certificate this phone doesn't trust, so nothing was sent to it."
        case .identityMismatch:
            return "The gateway identity no longer matches the preview. Stop and verify the host before scanning a new invitation."
        case .pairingUnavailable:
            return "\(where_.capitalizedFirst) doesn't support pairing links (it may be an older version, or pairing isn't enabled). Ask the host owner to verify their installed Hermes pairing support."
        case .rateLimited:
            return "The gateway asked this phone to slow down. Wait a minute and try again."
        case .unsupportedAccess:
            return "This link asks for access this version of Hermes Fleet doesn't understand, so it wasn't approved."
        case .malformedResponse, .serverError:
            return "\(where_.capitalizedFirst) answered with something that isn't the pairing protocol. Nothing was added."
        case .interrupted:
            return "The connection dropped before this phone heard back. The link may have been used. If adding fails again, ask for a new link."
        case .rollbackUnconfirmed:
            return "This phone could not save the connection. Cleanup was not confirmed. Retry cleanup; if it still fails, ask the owner to check and revoke this phone in the gateway device list before making a new invitation."
        case .couldNotSave:
            return "The gateway accepted the link but this phone couldn't save it, so nothing was added and the new device was revoked. Ask for a new link."
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
