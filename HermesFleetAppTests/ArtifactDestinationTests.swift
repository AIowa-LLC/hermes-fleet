import XCTest
import FleetCore
import FleetPersistence
import FleetUI

/// Card D — the Artifacts destination + inline chat media.
///
/// Hermetic coverage of:
/// - the shared retrieval store (per-reference dedupe, sticky failures,
///   terminal expiration, gateway-mismatch fail-closed, share-file staging);
/// - the device-local artifact library (source-qualified identity, upsert
///   dedupe, pruning, persistence);
/// - the honest copy for expired/missing states;
/// - the ConversationViewModel inline pipeline: a generation result becomes a
///   provenance-bound artifact on the CITING tool row, replayed frames never
///   duplicate it, non-generation tools attach nothing, and the model's
///   restated path/URL is stripped from the rendered prose while the
///   persisted transcript keeps the raw text.
@MainActor
final class ArtifactDestinationTests: XCTestCase {

    private let gateway = GatewayID(rawValue: "workstation")
    private let otherGateway = GatewayID(rawValue: "render-box")
    private var route: Route {
        Route(gatewayID: gateway, profileSlug: ProfileSlug(rawValue: "default"))
    }

    /// A real 1x1 PNG (decodable by UIImage — the store's preview path).
    private static let pngBytes = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    // MARK: - Scripted retriever

    private final class ScriptedRetriever: ArtifactRetrieving, @unchecked Sendable {
        let gatewayID: GatewayID
        private let lock = NSLock()
        private var outcomes: [Result<Data, ArtifactTransportError>]
        private var _calls: [ArtifactReference] = []

        init(gatewayID: GatewayID, outcomes: [Result<Data, ArtifactTransportError>]) {
            self.gatewayID = gatewayID
            self.outcomes = outcomes
        }

        var calls: [ArtifactReference] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        var callCount: Int { calls.count }

        func retrieve(_ reference: ArtifactReference) async throws -> RetrievedArtifact {
            let outcome: Result<Data, ArtifactTransportError> = lock.withLock {
                _calls.append(reference)
                return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
            }
            switch outcome {
            case .success(let data):
                return RetrievedArtifact(reference: reference, data: data, mimeType: "image/png")
            case .failure(let error):
                throw error
            }
        }
    }

    private func reference(
        path: String = "/home/u/.hermes/cache/images/cat.png",
        gateway: GatewayID? = nil,
        sessionID: String? = "s-1"
    ) -> ArtifactReference {
        ArtifactReference(
            gatewayID: gateway ?? self.gateway,
            sessionID: sessionID,
            profile: "default",
            path: path)
    }

    // MARK: - Retrieval store: dedupe

    func testStoreDeduplicatesConcurrentLoads() async {
        let store = ArtifactImageStore()
        let retriever = ScriptedRetriever(gatewayID: gateway, outcomes: [.success(Self.pngBytes)])
        let target = reference()

        async let first = store.load(target, using: retriever)
        async let second = store.load(target, using: retriever)
        let (a, b) = await (first, second)

        XCTAssertEqual(retriever.callCount, 1, "concurrent loads must share one fetch")
        XCTAssertEqual(a, b)
        if case .loaded(let payload) = a {
            XCTAssertEqual(payload.byteCount, Self.pngBytes.count)
            XCTAssertEqual(payload.mimeType, "image/png")
            XCTAssertEqual(payload.reference, target)
        } else {
            XCTFail("expected .loaded, got \(String(describing: a))")
        }
    }

    func testStoreReusesLoadedBytesWithoutRefetching() async {
        let store = ArtifactImageStore()
        let retriever = ScriptedRetriever(gatewayID: gateway, outcomes: [.success(Self.pngBytes)])
        let target = reference()

        _ = await store.load(target, using: retriever)
        _ = await store.load(target, using: retriever)
        _ = await store.load(target, using: retriever)

        XCTAssertEqual(retriever.callCount, 1, "a loaded reference is never re-fetched")
        XCTAssertNotNil(store.image(for: target), "PNG bytes decode for preview")
    }

    func testDistinctReferencesFetchSeparately() async {
        let store = ArtifactImageStore()
        let retriever = ScriptedRetriever(gatewayID: gateway, outcomes: [.success(Self.pngBytes)])

        _ = await store.load(reference(path: "/home/u/.hermes/cache/images/a.png"), using: retriever)
        _ = await store.load(reference(path: "/home/u/.hermes/cache/images/b.png"), using: retriever)

        XCTAssertEqual(retriever.callCount, 2)
    }

    // MARK: - Retrieval store: honest failure states

    func testFailureIsStickyUntilExplicitRetry() async {
        let store = ArtifactImageStore()
        let retriever = ScriptedRetriever(gatewayID: gateway, outcomes: [
            .failure(.timedOut(detail: "fixture")),
            .success(Self.pngBytes),
        ])
        let target = reference()

        let first = await store.load(target, using: retriever)
        XCTAssertEqual(first, .failed(.timedOut(detail: "fixture")))
        // A re-render / replayed event must NOT auto-retry.
        _ = await store.load(target, using: retriever)
        XCTAssertEqual(retriever.callCount, 1)

        let retried = await store.retry(target, using: retriever)
        XCTAssertEqual(retriever.callCount, 2)
        if case .loaded = retried {} else { XCTFail("expected .loaded after explicit retry") }
    }

    func testExpirationIsTerminalAndNeverRetried() async {
        let store = ArtifactImageStore()
        let retriever = ScriptedRetriever(gatewayID: gateway, outcomes: [
            .failure(.expired(detail: "File not found")),
        ])
        let target = reference()

        let first = await store.load(target, using: retriever)
        XCTAssertEqual(first, .failed(.expired(detail: "File not found")))
        let retried = await store.retry(target, using: retriever)
        XCTAssertEqual(retried, .failed(.expired(detail: "File not found")))
        XCTAssertEqual(retriever.callCount, 1, "an aged-out artifact cannot come back by asking again")
    }

    func testGatewayMismatchFailsClosedWithoutAnyRequest() async {
        let store = ArtifactImageStore()
        let retriever = ScriptedRetriever(gatewayID: otherGateway, outcomes: [.success(Self.pngBytes)])
        let target = reference(gateway: gateway)

        let state = await store.load(target, using: retriever)
        XCTAssertEqual(state, .failed(.gatewayMismatch(expected: otherGateway, actual: gateway)))
        XCTAssertEqual(retriever.callCount, 0, "one gateway's path must never meet another's credential")
    }

    func testShareFileUsesTheDisplayNameOnly() async {
        let store = ArtifactImageStore()
        let retriever = ScriptedRetriever(gatewayID: gateway, outcomes: [.success(Self.pngBytes)])
        let target = reference(path: "/home/u/.hermes/private/profile/cache/images/cat.png")
        _ = await store.load(target, using: retriever)

        let url = store.shareFileURL(for: target)
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.lastPathComponent.hasSuffix("cat.png") == true)
        XCTAssertFalse(url?.path.contains("private/profile") == true, "the gateway path never becomes a filename")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url?.path ?? ""))
    }

    func testClearGatewayDropsItsEntriesOnly() async {
        let store = ArtifactImageStore()
        let retriever = ScriptedRetriever(gatewayID: gateway, outcomes: [.success(Self.pngBytes)])
        let mine = reference(path: "/home/u/.hermes/cache/images/mine.png")
        let theirs = reference(path: "/home/u/.hermes/cache/images/theirs.png", gateway: otherGateway)
        _ = await store.load(mine, using: retriever)
        let otherRetriever = ScriptedRetriever(gatewayID: otherGateway, outcomes: [.success(Self.pngBytes)])
        _ = await store.load(theirs, using: otherRetriever)

        store.clear(gatewayID: gateway)
        XCTAssertNil(store.state(for: mine))
        XCTAssertNotNil(store.state(for: theirs))
    }

    // MARK: - Honest copy

    func testExpirationCopyOffersNoRetryAndTransientFailuresDo() {
        XCTAssertFalse(ArtifactRetrievalCopy.failure(for: .expired(detail: "x")).canRetry)
        XCTAssertFalse(ArtifactRetrievalCopy.failure(for: .notPermitted(detail: "x")).canRetry)
        XCTAssertTrue(ArtifactRetrievalCopy.failure(for: .timedOut(detail: "x")).canRetry)
        XCTAssertTrue(ArtifactRetrievalCopy.failure(for: .transferFailed(detail: "x")).canRetry)
        XCTAssertTrue(ArtifactRetrievalCopy.failure(for: .authenticationRequired(detail: "x")).canRetry)
    }

    func testFailureCopyNeverLeaksTheGatewayPath() {
        let failure = ArtifactRetrievalCopy.failure(for: .expired(detail: "/home/u/.hermes/cache/images/secret.png"))
        XCTAssertFalse(failure.detail.contains("/home/u/"))
        XCTAssertFalse(failure.title.contains("secret"))
    }

    // MARK: - Device-local artifact library

    private func makeLibrary() -> FleetArtifactLibrary {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-artifact-library-\(UUID().uuidString).json")
        return FleetArtifactLibrary(url: url)
    }

    func testLibraryUpsertsByGatewayAndPath() {
        let library = makeLibrary()
        library.record(reference: reference(), sourceTitle: "First title", sourceSubtitle: "default")
        library.record(reference: reference(), sourceTitle: "Renamed later", sourceSubtitle: "default")

        let entries = library.entries()
        XCTAssertEqual(entries.count, 1, "the same gateway+path is one artifact")
        XCTAssertEqual(entries.first?.sourceTitle, "Renamed later")
        XCTAssertEqual(entries.first?.name, "cat.png")
    }

    func testLibraryKeepsSameBasenameOnDifferentGateways() {
        let library = makeLibrary()
        library.record(reference: reference(gateway: gateway), sourceTitle: nil, sourceSubtitle: nil)
        library.record(reference: reference(gateway: otherGateway), sourceTitle: nil, sourceSubtitle: nil)
        XCTAssertEqual(library.entries().count, 2)
        XCTAssertEqual(library.entries(for: gateway).count, 1)
        XCTAssertEqual(library.entries(for: otherGateway).count, 1)
    }

    func testLibraryPrunesRemovedGatewaysAndPersists() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-artifact-library-\(UUID().uuidString).json")
        let library = FleetArtifactLibrary(url: url)
        library.record(reference: reference(gateway: gateway), sourceTitle: "Kept", sourceSubtitle: nil)
        library.record(reference: reference(gateway: otherGateway), sourceTitle: "Removed", sourceSubtitle: nil)

        library.prune(gatewayID: otherGateway)
        XCTAssertEqual(library.entries().map(\.sourceTitle), ["Kept"])

        // A fresh instance reads the persisted file.
        let reloaded = FleetArtifactLibrary(url: url)
        XCTAssertEqual(reloaded.entries().map(\.sourceTitle), ["Kept"])
    }

    func testLibraryPruneToRegisteredGateways() {
        let library = makeLibrary()
        library.record(reference: reference(gateway: gateway), sourceTitle: nil, sourceSubtitle: nil)
        library.record(reference: reference(gateway: otherGateway), sourceTitle: nil, sourceSubtitle: nil)
        library.pruneToRegisteredGateways([gateway.rawValue])
        XCTAssertEqual(library.entries().count, 1)
        XCTAssertEqual(library.entries().first?.gatewayIDRaw, gateway.rawValue)
    }

    func testLibraryEntryRebuildsItsReference() {
        let library = makeLibrary()
        library.record(reference: reference(sessionID: "s-9"), sourceTitle: "Chat", sourceSubtitle: "default")
        let entry = library.entries().first
        XCTAssertEqual(entry?.reference.path, "/home/u/.hermes/cache/images/cat.png")
        XCTAssertEqual(entry?.reference.sessionID, "s-9")
        XCTAssertEqual(entry?.reference.profile, "default")
    }

    // MARK: - Inline chat media (ConversationViewModel)

    private func makeViewModel(session: ScriptedSession) -> ConversationViewModel {
        ConversationViewModel(
            session: session,
            cache: try! SwiftDataCacheStore.makeInMemory(),
            route: route,
            sessionID: nil,
            statusInterval: .milliseconds(10))
    }

    private func flush() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    func testGenerationResultAttachesArtifactToTheCitingToolRow() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        var observed: [(ArtifactReference, String?, String?)] = []
        model.onArtifactObserved = { reference, title, profile in
            observed.append((reference, title, profile))
        }
        await model.start()

        session.push(.toolStart(sessionID: "s-1", toolID: "t-img", name: "image_generate", context: "draw a cat", argsText: nil))
        session.push(.toolComplete(
            sessionID: "s-1", toolID: "t-img", name: "image_generate", summary: nil,
            resultText: #"{"success": true, "image": "/home/u/.hermes/cache/images/generated_1.png"}"#))
        await flush()

        let toolRow = model.transcript.first { $0.kind == .tool }
        XCTAssertEqual(toolRow?.artifacts?.count, 1)
        let reference = toolRow?.artifacts?.first
        XCTAssertEqual(reference?.gatewayID, gateway)
        XCTAssertEqual(reference?.sessionID, "s-1")
        XCTAssertEqual(reference?.profile, "default")
        XCTAssertEqual(reference?.path, "/home/u/.hermes/cache/images/generated_1.png")
        XCTAssertEqual(reference?.displayName, "generated_1.png")
        XCTAssertEqual(observed.count, 1, "the library sink sees each identity once")
        XCTAssertEqual(observed.first?.0, reference)
    }

    func testReplayedGenerationFrameNeverDuplicatesTheArtifact() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        var observedCount = 0
        model.onArtifactObserved = { _, _, _ in observedCount += 1 }
        await model.start()

        let frames: [ConversationEvent] = [
            .toolStart(sessionID: "s-1", toolID: "t-img", name: "image_generate", context: "draw a cat", argsText: nil),
            .toolComplete(
                sessionID: "s-1", toolID: "t-img", name: "image_generate", summary: nil,
                resultText: #"{"success": true, "image": "/home/u/.hermes/cache/images/generated_1.png"}"#),
        ]
        for event in frames { session.push(event) }
        await flush()
        // Reconnect/replay: the same frames arrive again.
        for event in frames { session.push(event) }
        await flush()

        let toolRows = model.transcript.filter { $0.kind == .tool }
        XCTAssertEqual(toolRows.count, 1, "the replayed tool.start adopts the existing row")
        XCTAssertEqual(toolRows.first?.artifacts?.count, 1, "the replayed result never duplicates the artifact")
        XCTAssertEqual(observedCount, 1, "no duplicate library observation on replay")
    }

    func testNonGenerationToolsAttachNothing() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        session.push(.toolStart(sessionID: "s-1", toolID: "t1", name: "web_search", context: "cats", argsText: nil))
        session.push(.toolComplete(
            sessionID: "s-1", toolID: "t1", name: "web_search", summary: "3 results",
            resultText: #"{"data": {"web": [1,2,3]}}"#))
        await flush()

        let toolRow = model.transcript.first { $0.kind == .tool }
        XCTAssertNil(toolRow?.artifacts)
    }

    func testFailedGenerationAttachesNothing() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        session.push(.toolStart(sessionID: "s-1", toolID: "t-img", name: "image_generate", context: "draw a cat", argsText: nil))
        session.push(.toolComplete(
            sessionID: "s-1", toolID: "t-img", name: "image_generate", summary: nil,
            resultText: #"{"success": false, "image": "/home/u/.hermes/cache/images/never.png", "error": "boom"}"#))
        await flush()

        XCTAssertNil(model.transcript.first { $0.kind == .tool }?.artifacts)
    }

    func testURLOnlyResultStripsTheProseEchoWithoutAttachingAnArtifact() async {
        let session = ScriptedSession(gatewayID: gateway)
        let cache = try! SwiftDataCacheStore.makeInMemory()
        let model = ConversationViewModel(
            session: session, cache: cache, route: route, sessionID: nil,
            statusInterval: .milliseconds(10))
        await model.start()

        session.push(.toolStart(sessionID: "s-1", toolID: "t-img", name: "image_generate", context: "draw a cat", argsText: nil))
        session.push(.toolComplete(
            sessionID: "s-1", toolID: "t-img", name: "image_generate", summary: nil,
            resultText: #"{"success": true, "image": "https://fal.media/files/cat.png"}"#))
        session.push(.messageStart(sessionID: "s-1"))
        session.push(.messageDelta(sessionID: "s-1", text: "Here: https://fal.media/files/cat.png enjoy", rendered: nil))
        session.push(.messageComplete(
            sessionID: "s-1", text: "Here: https://fal.media/files/cat.png enjoy",
            status: nil, error: nil))
        await flush()

        // No gateway-local path ⇒ nothing retrievable ⇒ no inline artifact.
        XCTAssertNil(model.transcript.first { $0.kind == .tool }?.artifacts)
        // The rendered prose no longer restates the URL (the artifact slot is
        // the single presentation), while the persisted transcript keeps the
        // raw wire text.
        let assistant = model.transcript.first { $0.kind == .assistant }
        XCTAssertEqual(assistant?.text, "Here:  enjoy")
        let persisted = try? await cache.loadHistory(sessionID: "s-1", for: gateway)
        XCTAssertEqual(persisted?.messages.first { $0.role == .assistant }?.text,
                       "Here: https://fal.media/files/cat.png enjoy")
    }

    func testEchoStrippingIsTurnScoped() async {
        let session = ScriptedSession(gatewayID: gateway)
        let model = makeViewModel(session: session)
        await model.start()

        // Turn 1: an image generation, then its reply.
        session.push(.toolStart(sessionID: "s-1", toolID: "t-img", name: "image_generate", context: "draw a cat", argsText: nil))
        session.push(.toolComplete(
            sessionID: "s-1", toolID: "t-img", name: "image_generate", summary: nil,
            resultText: #"{"success": true, "image": "/home/u/.hermes/cache/images/cat.png"}"#))
        session.push(.messageStart(sessionID: "s-1"))
        session.push(.messageDelta(sessionID: "s-1", text: "Saved /home/u/.hermes/cache/images/cat.png", rendered: nil))
        session.push(.messageComplete(
            sessionID: "s-1", text: "Saved /home/u/.hermes/cache/images/cat.png", status: nil, error: nil))
        await flush()
        // Turn 2: a NEW reply that legitimately quotes the same path.
        session.push(.messageStart(sessionID: "s-1"))
        session.push(.messageDelta(sessionID: "s-1", text: "The file /home/u/.hermes/cache/images/cat.png exists", rendered: nil))
        session.push(.messageComplete(
            sessionID: "s-1", text: "The file /home/u/.hermes/cache/images/cat.png exists",
            status: nil, error: nil))
        await flush()

        let assistantRows = model.transcript.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantRows.count, 2)
        XCTAssertEqual(assistantRows[0].text.trimmingCharacters(in: .whitespaces), "Saved")
        XCTAssertEqual(assistantRows[1].text, "The file /home/u/.hermes/cache/images/cat.png exists",
                       "another turn's artifact never scrubs prose it did not cite")
    }

    // MARK: - Scripted session double

    /// Minimal `ConversationSessionProviding` for the inline-media pipeline:
    /// pushable events + scripted create/resume/replay/history.
    private final class ScriptedSession:
        ConversationSessionProviding,
        ConversationProviding,
        ReplayProviding,
        SessionHistoryProviding,
        @unchecked Sendable
    {
        let gatewayID: GatewayID
        private let streamPair: (AsyncStream<ConversationEvent>, AsyncStream<ConversationEvent>.Continuation)

        init(gatewayID: GatewayID) {
            self.gatewayID = gatewayID
            self.streamPair = AsyncStream.makeStream()
        }

        func push(_ event: ConversationEvent) {
            streamPair.1.yield(event)
        }

        // GatewayConnectivityProviding
        var status: GatewayStatus { .online }
        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "epoch-1", heartbeatEnabled: true, changeEventsEnabled: true)
        }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "Workstation")
        }

        // ConversationSessionProviding
        var conversation: any ConversationProviding { self }
        var replay: any ReplayProviding { self }
        var history: any SessionHistoryProviding { self }
        func reauthenticate() async throws {}

        // ConversationProviding
        var events: AsyncStream<ConversationEvent> { streamPair.0 }
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            ConversationSession(sessionID: "s-1", profileName: "default")
        }
        func resumeSession(sessionID: String, lastEventID: Int?, profile: String? = nil) async throws -> ConversationSession {
            ConversationSession(sessionID: sessionID, profileName: "default")
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
            PromptSubmission(status: "streaming")
        }
        func interrupt(sessionID: String) async throws -> InterruptResult {
            InterruptResult(status: "interrupted")
        }
        /// This double never gaps: nothing to resume.
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }

        // ReplayProviding
        func watermarks() async -> [SessionEventWatermark] { [] }
        func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }

        // SessionHistoryProviding
        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
            SessionHistory(sessionID: sessionID, count: 0, messages: [])
        }
        func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
            SessionStatus(rawOutput: "ok")
        }
    }
}
