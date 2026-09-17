import Foundation
import Observation
import FleetCore
import UIKit

/// Card D — the shared artifact retrieval store: one in-memory entry per
/// `ArtifactReference` (identity = gateway + path + source), so the SAME
/// reference rendered from a live turn, a replayed frame, or the artifacts
/// destination never fetches twice and never duplicates (the dedupe contract
/// on replay/reconnect).
///
/// State machine per reference:
/// - absent → `load()` fetches through the gateway's `ArtifactRetrieving` seam;
/// - `.loading` → concurrent callers join the in-flight fetch (no second GET);
/// - `.loaded` → reused as-is (bytes are real; nothing re-derives them);
/// - `.failed` → sticky until an explicit `retry()` (a re-render or a replayed
///   event must never auto-retry a 404/403 in a loop). Expiration (404) is
///   terminal: the gateway's own cache retention aged the artifact out and a
///   retry cannot bring it back — the UI says so instead.
///
/// Memory discipline: decoded payloads are capped (`maxLoadedPayloads`,
/// oldest-inserted evicted first). Eviction only drops the local copy — the
/// gateway remains the source of truth; re-visiting re-fetches.
@MainActor
@Observable
public final class ArtifactImageStore {

    /// One successfully retrieved artifact (real bytes + provenance).
    public struct Payload: Equatable, Sendable {
        public let reference: ArtifactReference
        public let data: Data
        public let mimeType: String
        public var byteCount: Int { data.count }
    }

    public enum State: Equatable, Sendable {
        case loading
        case loaded(Payload)
        case failed(ArtifactTransportError)
    }

    /// How many retrieved payloads are retained in memory at once.
    public static let maxLoadedPayloads = 16

    public private(set) var states: [ArtifactReference: State] = [:]

    /// Insertion order for eviction (references whose payload is retained).
    private var loadedOrder: [ArtifactReference] = []
    /// Decoded images (never part of `states` — decoding is presentation).
    private var decoded: [ArtifactReference: UIImage] = [:]
    /// Serializes concurrent `load()` calls for the same reference.
    private var inFlight: [ArtifactReference: Task<State, Never>] = [:]
    /// Share-file staging (lazily written per reference).
    private var shareFiles: [ArtifactReference: URL] = [:]

    public init() {}

    // MARK: Reads

    /// Current state, or nil when the reference has never been touched.
    public func state(for reference: ArtifactReference) -> State? {
        states[reference]
    }

    /// Decoded image for a loaded reference (nil while absent/undecodable —
    /// e.g. SVG/ICO payloads, which are shareable but not previewable here).
    public func image(for reference: ArtifactReference) -> UIImage? {
        decoded[reference]
    }

    /// A file URL holding the retrieved bytes, for ShareLink/activity sharing.
    /// Written lazily under the app's temporary directory using only the
    /// DISPLAY name (the gateway path never becomes a filename). Nil until the
    /// artifact has been retrieved.
    public func shareFileURL(for reference: ArtifactReference) -> URL? {
        if let existing = shareFiles[reference],
           FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }
        guard case .loaded(let payload) = states[reference] else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = ArtifactTransportRules.defaultName(forPath: reference.name)
        let url = directory.appendingPathComponent("\(stableID(for: reference))-\(stem)")
        do {
            try payload.data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        shareFiles[reference] = url
        return url
    }

    // MARK: Fetch

    /// Fetch `reference` through `retriever` unless it is already
    /// loading/loaded. Concurrent callers join the same in-flight fetch. A
    /// `.failed` entry is returned as-is — retry is explicit (`retry()`).
    @discardableResult
    public func load(_ reference: ArtifactReference, using retriever: any ArtifactRetrieving) async -> State? {
        if let existing = states[reference] {
            switch existing {
            case .loaded, .failed:
                return existing
            case .loading:
                break
            }
        }
        guard let retriever = retrieverForGateway(reference.gatewayID, candidate: retriever) else {
            return record(.failed(.gatewayMismatch(
                expected: retriever.gatewayID, actual: reference.gatewayID)), for: reference)
        }
        if let task = inFlight[reference] {
            return await task.value
        }
        states[reference] = .loading
        let task = Task<State, Never> { [weak self] in
            do {
                let retrieved = try await retriever.retrieve(reference)
                let payload = Payload(
                    reference: retrieved.reference,
                    data: retrieved.data,
                    mimeType: retrieved.mimeType)
                await MainActor.run { self?.store(.loaded(payload), for: reference) }
                return .loaded(payload)
            } catch let error as ArtifactTransportError {
                await MainActor.run { self?.store(.failed(error), for: reference) }
                return .failed(error)
            } catch {
                let classified = ArtifactTransportError.transferFailed(detail: Redaction.safeErrorDescription(error))
                await MainActor.run { self?.store(.failed(classified), for: reference) }
                return .failed(classified)
            }
        }
        inFlight[reference] = task
        let state = await task.value
        inFlight[reference] = nil
        return state
    }

    /// Explicit user retry. Expiration (404) is terminal — the gateway no
    /// longer serves the artifact, and re-requesting cannot change that — so
    /// it is NOT retried; every other failure class is.
    @discardableResult
    public func retry(_ reference: ArtifactReference, using retriever: any ArtifactRetrieving) async -> State? {
        if case .failed(let error) = states[reference], error.isExpiration {
            return states[reference]
        }
        states[reference] = nil
        decoded[reference] = nil
        return await load(reference, using: retriever)
    }

    /// Forget everything for one gateway (gateway removal / invalidation).
    public func clear(gatewayID: GatewayID) {
        for reference in states.keys where reference.gatewayID == gatewayID {
            states[reference] = nil
            decoded[reference] = nil
            shareFiles[reference] = nil
        }
        loadedOrder.removeAll { $0.gatewayID == gatewayID }
        inFlight = inFlight.filter { $0.key.gatewayID != gatewayID }
    }

    public func removeAll() {
        states.removeAll()
        decoded.removeAll()
        shareFiles.removeAll()
        loadedOrder.removeAll()
        inFlight.removeAll()
    }

    // MARK: Internals

    /// The retriever is only trusted for its own gateway: one gateway's path
    /// must never be presented to another gateway's credential (fail closed).
    private func retrieverForGateway(_ gatewayID: GatewayID, candidate: any ArtifactRetrieving) -> (any ArtifactRetrieving)? {
        candidate.gatewayID == gatewayID ? candidate : nil
    }

    private func store(_ state: State, for reference: ArtifactReference) {
        switch state {
        case .loaded(let payload):
            evictIfNeeded(beforeInserting: reference)
            states[reference] = .loaded(payload)
            if let image = UIImage(data: payload.data) {
                decoded[reference] = image
            }
            loadedOrder.removeAll { $0 == reference }
            loadedOrder.append(reference)
        case .loading, .failed:
            states[reference] = state
        }
    }

    private func record(_ state: State, for reference: ArtifactReference) -> State {
        store(state, for: reference)
        return state
    }

    private func evictIfNeeded(beforeInserting reference: ArtifactReference) {
        guard !loadedOrder.contains(reference) else { return }
        while loadedOrder.count >= Self.maxLoadedPayloads {
            let oldest = loadedOrder.removeFirst()
            if case .loaded = states[oldest] {
                states[oldest] = nil
                decoded[oldest] = nil
                shareFiles[oldest] = nil
            }
        }
    }

    /// Deterministic (non-random) id for staging files — derived from the
    /// reference identity, never from the raw path.
    private func stableID(for reference: ArtifactReference) -> String {
        var hasher = Hasher()
        hasher.combine(reference)
        return "artifact-\(UInt(bitPattern: hasher.finalize()))"
    }
}

// MARK: - Honest copy for the retrieval states

/// Card D — user-facing copy for artifact retrieval outcomes. Never contains
/// the gateway path; expiration says what actually happened (host-side cache
/// retention) instead of implying the app lost something.
public enum ArtifactRetrievalCopy {

    public struct Failure: Equatable, Sendable {
        public let title: String
        public let detail: String
        /// Whether an explicit retry can plausibly change the outcome.
        public let canRetry: Bool

        public init(title: String, detail: String, canRetry: Bool) {
            self.title = title
            self.detail = detail
            self.canRetry = canRetry
        }
    }

    public static func failure(for error: ArtifactTransportError) -> Failure {
        switch error {
        case .expired:
            return Failure(
                title: "No longer on the gateway",
                detail: "The gateway no longer serves this image — its cache has aged it out.",
                canRetry: false)
        case .notPermitted:
            return Failure(
                title: "Not available",
                detail: "The gateway refused this image. It may have been moved or removed.",
                canRetry: false)
        case .unsupportedType:
            return Failure(
                title: "Can't preview this type",
                detail: "The gateway served a format this app doesn't display.",
                canRetry: false)
        case .tooLarge:
            return Failure(
                title: "Too large to load",
                detail: "This image is larger than the app will transfer from a gateway.",
                canRetry: false)
        case .authenticationRequired:
            return Failure(
                title: "Sign-in needed",
                detail: "The gateway needs a fresh sign-in before it will serve this image.",
                canRetry: true)
        case .gatewayMismatch:
            return Failure(
                title: "Wrong gateway",
                detail: "This image belongs to another gateway.",
                canRetry: false)
        case .invalidReference:
            return Failure(
                title: "Can't load this image",
                detail: "The reference isn't a form this app can request from a gateway.",
                canRetry: false)
        case .notConfigured:
            return Failure(
                title: "Artifacts unavailable",
                detail: "This build has no gateway artifact transport configured.",
                canRetry: false)
        case .malformedResponse:
            return Failure(
                title: "Unexpected response",
                detail: "The gateway's answer didn't match the media contract.",
                canRetry: true)
        case .transferFailed:
            return Failure(
                title: "Couldn't reach the gateway",
                detail: "The transfer failed before the image arrived.",
                canRetry: true)
        case .timedOut:
            return Failure(
                title: "Transfer timed out",
                detail: "The image didn't arrive in time.",
                canRetry: true)
        }
    }
}
