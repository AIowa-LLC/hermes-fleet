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
    func revokeUnsavedDevice(_ grant: PairingGrant) async
    /// Name shown to the gateway owner in their device list.
    var pairingDeviceName: String { get }
}

/// The Add to Fleet flow, end to end:
///
///     receive link ─▶ preview (no side effect) ─▶ person confirms ─▶ redeem ─▶ save ─▶ done
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
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(
        service: (any GatewayPairing)?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.now = now
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

    // MARK: Intake

    /// A URL the system delivered (Universal Link or open-URL). Returns whether it is a
    /// pairing link and was taken. A malformed pairing link is still "taken", so the person
    /// gets a clear message instead of nothing.
    @discardableResult
    public func receive(url: URL) -> Bool {
        guard PairingInvitationLink.looksLikePairingLink(url) else { return false }
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
        cancelTask()
        link = nil
        flowID += 1
        entry = .manual
        phase = service == nil ? .failed(.pairingUnavailable, host: nil) : .awaitingLink
    }

    private var isBusy: Bool {
        switch phase {
        case .previewing, .redeeming: return true
        default: return false
        }
    }

    private func start(entry: Entry, text: String) {
        // A second delivery of the very same link (the system can report one tap through two
        // callbacks) must not restart a flow already underway.
        if let active = link, let incoming = try? PairingInvitationLink.parse(text),
           active.invitationID == incoming.invitationID, active.origin == incoming.origin,
           phase != .idle, !isTerminal {
            return
        }
        // Never abandon a redemption that is in flight.
        if case .redeeming = phase { return }
        cancelTask()
        flowID += 1
        self.entry = entry
        guard service != nil else {
            link = nil
            phase = .failed(.pairingUnavailable, host: nil)
            return
        }
        do {
            let parsed = try PairingInvitationLink.parse(text)
            link = parsed
            phase = .previewing(host: parsed.host)
            task = Task { [weak self] in await self?.runPreview() }
        } catch {
            link = nil
            phase = .failed(Self.failure(for: error), host: nil)
        }
    }

    private var isTerminal: Bool {
        switch phase {
        case .completed, .failed, .alreadyAdded: return true
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
            if !error.isRetryable { self.link = nil }
            phase = .failed(error, host: link.host)
        }
    }

    /// Retry after a retryable failure (offline, rate limited, interrupted preview).
    public func retry() {
        guard case .failed(let failure, _) = phase, failure.isRetryable, let link else { return }
        cancelTask()
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
        guard let host else {
            _ = await service.revoke(origin: grant.gateway.origin, credential: grant.credential)
            finish(.failed(.couldNotSave, host: link.host))
            return
        }
        do {
            let gateway = try await host.addPairedGateway(grant)
            finish(.completed(name: gateway.displayName))
        } catch {
            await host.revokeUnsavedDevice(grant)
            finish(.failed(.couldNotSave, host: link.host))
        }
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
        case .unreachable: return "Can't reach the gateway"
        case .untrustedCertificate: return "Gateway certificate not trusted"
        case .identityMismatch: return "The gateway changed"
        case .pairingUnavailable: return "Pairing isn't available here"
        case .rateLimited: return "Too many attempts"
        case .unsupportedAccess: return "Unsupported access request"
        case .malformedResponse, .serverError: return "The gateway didn't answer correctly"
        case .interrupted: return "Pairing was interrupted"
        case .couldNotSave: return "Couldn't add the gateway"
        }
    }

    public static func message(for failure: PairingFailure, host: String?) -> String {
        let where_ = host.map { "“\($0)”" } ?? "the gateway"
        switch failure {
        case .expired:
            return "Pairing links only work for a few minutes. Ask for a new one from Hermes and open it again."
        case .alreadyUsed:
            return "A pairing link works once. If you didn't use it, someone else may have — ask for a new link and check the device list on the gateway."
        case .cancelled:
            return "The owner cancelled this link, or it was locked after too many wrong tries. Ask for a new one."
        case .invalidInvitation:
            return "\(where_.capitalizedFirst) doesn't recognise this link. Check that it was copied completely, or ask for a new one."
        case .malformedLink:
            return "Paste a Hermes Fleet pairing link (it starts with https:// and ends with a long code), or scan its QR code."
        case .unsupportedLinkVersion:
            return "This link was made for a newer version of Hermes Fleet. Update the app, then open it again."
        case .insecureDestination:
            return "Pairing links must be https links to a real gateway address. Nothing was contacted."
        case .unreachable:
            return "This phone couldn't connect to \(where_). A pairing link doesn't create a network path: the gateway must be reachable from this phone (internet, VPN or the same network). Check your connection and try again."
        case .untrustedCertificate:
            return "\(where_.capitalizedFirst) presented a certificate this phone doesn't trust, so nothing was sent to it."
        case .identityMismatch:
            return "The gateway's identity changed while pairing, so nothing was sent. Open the link again; if this repeats, don't continue."
        case .pairingUnavailable:
            return "\(where_.capitalizedFirst) doesn't support pairing links (it may be an older version, or pairing isn't enabled). Add it with its address and sign-in instead."
        case .rateLimited:
            return "The gateway asked this phone to slow down. Wait a minute and try again."
        case .unsupportedAccess:
            return "This link asks for access this version of Hermes Fleet doesn't understand, so it wasn't approved."
        case .malformedResponse, .serverError:
            return "\(where_.capitalizedFirst) answered with something that isn't the pairing protocol. Nothing was added."
        case .interrupted:
            return "The connection dropped before this phone heard back. The link may have been used. If adding fails again, ask for a new link."
        case .couldNotSave:
            return "The gateway accepted the link but this phone couldn't save it, so nothing was added and the new device was revoked. Ask for a new link."
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
