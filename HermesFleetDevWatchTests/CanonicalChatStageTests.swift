import XCTest
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

/// Exercises the real `AppEnvironment.resolveCanonicalChatTarget` with a fake
/// registry seam: which stage failed is reported, and a failed lookup NEVER
/// reaches creation (the fail-closed guard).
@MainActor
final class CanonicalChatStageTests: XCTestCase {
    private final class Seam: BotModeChatProviding, @unchecked Sendable {
        enum Lookup { case rows([CanonicalLookupRow]), error(Error) }
        let lookup: Lookup
        let createError: Error?
        nonisolated(unsafe) private(set) var lookups = 0
        nonisolated(unsafe) private(set) var creates = 0
        init(_ lookup: Lookup, createError: Error? = nil) { self.lookup = lookup; self.createError = createError }
        func lookupCanonicalChat(profile: String) async throws -> CanonicalLookup {
            lookups += 1
            switch lookup {
            case .rows(let rows): return CanonicalLookup(rows: rows)
            case .error(let e): throw e
            }
        }
        func createCanonicalChat(profile: String) async throws -> String {
            creates += 1
            if let createError { throw createError }
            return "created-1"
        }
    }

    private struct Roster: GatewayRosterSession {
        let gatewayID: GatewayID
        var status: GatewayStatus { .online }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: gatewayID.rawValue) }
        func fetchProfiles() async throws -> [ProfileDescriptor] { [] }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }
    private struct Sessions: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }
    private struct Health: ConnectionHealthAccumulating {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }
    private final class Conn: GatewayConnectivityProviding, @unchecked Sendable {
        let gatewayID: GatewayID
        init(_ id: GatewayID) { gatewayID = id }
        var status: GatewayStatus { .online }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: gatewayID.rawValue) }
    }

    private let gateway = GatewayID(rawValue: "mini")

    private func environment(_ seam: Seam) async -> AppEnvironment {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(credentials: credentials, connectionFactory: { g, _ in Conn(g.id) })
        let roster = FleetRosterService(registry: registry, credentials: credentials,
                                        sessionFactory: { g, _ in Roster(gatewayID: g.id) })
        let env = AppEnvironment(
            registry: registry, roster: roster, cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: Sessions(), connectionFactory: { g, _ in Conn(g.id) },
            botModeChatFactory: { _ in seam }, health: Health(),
            seedRegistrations: [GatewayRegistration(id: gateway, displayName: "Mini Hermes",
                                                    endpoint: URL(string: "http://127.0.0.1:9001")!)],
            connectionIntentDefaults: UserDefaults(suiteName: "canon-stage-\(UUID().uuidString)")!)
        await env.load()
        return env
    }

    private func bot(canonical: String? = nil) -> FleetBot {
        FleetBot(route: Route(gatewayID: gateway, profileSlug: ProfileSlug(rawValue: "apple")), displayName: "Apple",
                 canonicalSession: canonical.map { CanonicalSessionRef(id: $0) })
    }

    private func failure(_ result: Result<String, BotChatUnavailable>) -> BotChatUnavailable? {
        if case .failure(let f) = result { return f }
        return nil
    }

    func testLookupRPCErrorIsReportedAsLookupStageAndNeverCreates() async {
        let seam = Seam(.error(BotModeProfileError.unsupportedMethod("session.list")))
        let result = await (await environment(seam)).resolveCanonicalChatTarget(for: bot())
        let f = failure(result)
        XCTAssertEqual(f?.stage, .lookup)
        XCTAssertEqual(f?.errorCategory, "BotModeProfileError.unsupportedMethod", "case name only, never the payload")
        XCTAssertEqual(seam.lookups, 1)
        XCTAssertEqual(seam.creates, 0, "a failed lookup must never become an empty registry")
    }

    func testNotConnectedLookupIsDistinguishable() async {
        let seam = Seam(.error(RosterError.notConnected))
        let f = failure(await (await environment(seam)).resolveCanonicalChatTarget(for: bot()))
        XCTAssertEqual(f?.stage, .lookup)
        XCTAssertEqual(f?.errorCategory, "RosterError.notConnected")
        XCTAssertEqual(seam.creates, 0)
    }

    func testEmptyLookupWhenRosterKnowsACanonicalChatNeverCreates() async {
        let seam = Seam(.rows([]))
        let f = failure(await (await environment(seam)).resolveCanonicalChatTarget(for: bot(canonical: "known-1")))
        XCTAssertEqual(f?.stage, .unconfirmed)
        XCTAssertEqual(seam.creates, 0)
    }

    func testConfirmedMissCreatesAndCreationFailureIsItsOwnStage() async {
        let seam = Seam(.rows([]), createError: RosterError.rpcFailed("boom"))
        let f = failure(await (await environment(seam)).resolveCanonicalChatTarget(for: bot()))
        XCTAssertEqual(f?.stage, .create)
        XCTAssertEqual(seam.creates, 1)
        XCTAssertFalse((f?.errorCategory ?? "").contains("boom"))
    }

    func testExistingChatOpensWithoutCreate() async {
        let seam = Seam(.rows([CanonicalLookupRow(id: "reg-1", resolvedID: "tip-2", title: BotModeContract.canonicalChatTitle)]))
        let result = await (await environment(seam)).resolveCanonicalChatTarget(for: bot())
        XCTAssertEqual(try? result.get(), "tip-2")
        XCTAssertEqual(seam.creates, 0)
    }

    func testSafeErrorCategoryNeverIncludesPayload() {
        XCTAssertEqual(SafeErrorCategory.of(ConversationError.rpcFailed("token=abc123")), "ConversationError.rpcFailed")
        XCTAssertEqual(SafeErrorCategory.of(ConversationError.notConnected), "ConversationError.notConnected")
    }
}
