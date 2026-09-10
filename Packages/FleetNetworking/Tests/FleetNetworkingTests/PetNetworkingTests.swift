import XCTest
import FleetCore
@testable import FleetNetworking

/// #9 — pet.gallery / pet.thumb wire semantics against the in-process
/// WebSocket fixture: param propagation (profile, localOnly, url),
/// response decoding (typed pets, generated/curated flags, empty
/// spritesheetUrls → nil), PNG data-URI validation, honest
/// unsupported-capability detection (-32601 ≠ transient), and routing
/// through the client's own gateway transport.
final class PetNetworkingTests: XCTestCase {

    // MARK: helpers (mirror BotProfileNetworkingTests)

    private func makeTransport(serverPort: UInt16) -> GatewayWebSocketTransport {
        let base = URL(string: "http://127.0.0.1:\(serverPort)")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30),
            inboundDeadline: .seconds(30),
            connectTimeout: .seconds(10),
            requestTimeout: .seconds(2)
        )
        return GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: config
        )
    }

    private static func readyFrame() -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true,"heartbeat":false,"replay_epoch":"epoch-1"}}}"#
    }

    private static func extractRequest(_ frame: String) -> (id: String, method: String)? {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String else { return nil }
        return (id, method)
    }

    private static func responseFrame(id: String, resultObject: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","result":\#(resultObject)}"#
    }

    private static func errorFrame(id: String, code: Int, message: String) -> String {
        #"{"jsonrpc":"2.0","id":"\#(id)","error":{"code":\#(code),"message":"\#(message)"}}"#
    }

    /// Tiny valid PNG (8x8 solid magenta) as a data URI stand-in for the
    /// gateway's nearest-neighbor idle-frame thumbnail.
    private static let pngDataURL =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAEklEQVR4nGP4z7DoP8MoQS4BAPMYqAH2vyKxAAAAAElFTkSuQmCC"

    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [String] = []
        func record(_ frame: String) { lock.lock(); frames.append(frame); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return frames }
        func params(of method: String) -> [[String: Any]] {
            all.compactMap { frame in
                guard let data = frame.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      obj["method"] as? String == method else { return nil }
                return obj["params"] as? [String: Any]
            }
        }
    }

    private static let galleryResult = #"""
    {"enabled":true,"active":"spark-fox","pets":[
      {"slug":"spark-fox","displayName":"Spark Fox","installed":true,"spritesheetUrl":"","curated":false,"generated":false},
      {"slug":"pixel-owl","displayName":"Pixel Owl","installed":false,"spritesheetUrl":"https://petdex.dev/sheets/pixel-owl.png","curated":true,"generated":false},
      {"slug":"null-cat","displayName":"Null Cat","installed":true,"spritesheetUrl":"","curated":false,"generated":true}
    ]}
    """#

    // MARK: - pet.gallery

    func testGalleryDecodesTypedPetsAndPropagatesProfileAndLocalOnly() async throws {
        let log = RequestLog()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "pet.gallery" {
                    return [Self.responseFrame(id: id, resultObject: Self.galleryResult)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        let client = GatewayBotModeClient(
            gatewayID: GatewayID(rawValue: "g1"), transport: transport)

        // localOnly phase
        let local = try await client.petGallery(profile: "researcher", localOnly: true)
        let full = try await client.petGallery(profile: "researcher", localOnly: false)

        // Typed decoding.
        XCTAssertEqual(full.pets.count, 3)
        let fox = full.pets.first { $0.slug == "spark-fox" }
        XCTAssertEqual(fox?.displayName, "Spark Fox")
        XCTAssertEqual(fox?.installed, true)
        XCTAssertEqual(fox?.curated, false)
        XCTAssertEqual(fox?.generated, false)
        XCTAssertNil(fox?.spritesheetURL, "empty wire URL decodes to nil")
        let owl = full.pets.first { $0.slug == "pixel-owl" }
        XCTAssertEqual(owl?.spritesheetURL, "https://petdex.dev/sheets/pixel-owl.png")
        let cat = full.pets.first { $0.slug == "null-cat" }
        XCTAssertEqual(cat?.generated, true)
        XCTAssertEqual(full.displayEnabled, true)
        XCTAssertEqual(full.activeSlug, "spark-fox")

        // Param propagation: profile on every call, localOnly ONLY when
        // requested (its absence must be observable on the wire).
        let calls = log.params(of: "pet.gallery")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0]["profile"] as? String, "researcher")
        XCTAssertEqual(calls[0]["localOnly"] as? Bool, true)
        XCTAssertEqual(calls[1]["profile"] as? String, "researcher")
        XCTAssertNil(calls[1]["localOnly"])
    }

    func testGalleryMissingPetsIsMalformed() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "pet.gallery" {
                    return [Self.responseFrame(id: id, resultObject: #"{"enabled":false}"#)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        let client = GatewayBotModeClient(
            gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        do {
            _ = try await client.petGallery(profile: "p", localOnly: false)
            XCTFail("expected malformed")
        } catch let error as BotPetError {
            XCTAssertEqual(error, .malformed("pet.gallery missing 'pets'"))
        }
    }

    // MARK: - pet.thumb

    func testThumbDecodesPNGAndPropagatesParams() async throws {
        let log = RequestLog()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "pet.thumb" {
                    return [Self.responseFrame(id: id, resultObject:
                        #"{"ok":true,"slug":"pixel-owl","dataUri":"\#(Self.pngDataURL)"}"#)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        let client = GatewayBotModeClient(
            gatewayID: GatewayID(rawValue: "g1"), transport: transport)

        // Remote entry: profile + slug + url all propagate.
        let bytes = try await client.petThumbnail(
            profile: "researcher", slug: "pixel-owl",
            sourceURL: "https://petdex.dev/sheets/pixel-owl.png")
        XCTAssertTrue(bytes.starts(with: [0x89, 0x50]), "PNG signature preserved")
        let params = log.params(of: "pet.thumb").first
        XCTAssertEqual(params?["profile"] as? String, "researcher")
        XCTAssertEqual(params?["slug"] as? String, "pixel-owl")
        XCTAssertEqual(params?["url"] as? String, "https://petdex.dev/sheets/pixel-owl.png")

        // Local/generated entry: NO url param on the wire.
        _ = try await client.petThumbnail(profile: "researcher", slug: "null-cat", sourceURL: nil)
        let secondParams = log.params(of: "pet.thumb")[1]
        XCTAssertNil(secondParams["url"], "local pets must not send url")
    }

    func testThumbOKFalseIsThumbnailUnavailable() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "pet.thumb" {
                    return [Self.responseFrame(id: id, resultObject: #"{"ok":false,"slug":"ghost"}"#)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        let client = GatewayBotModeClient(
            gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        do {
            _ = try await client.petThumbnail(profile: "p", slug: "ghost", sourceURL: nil)
            XCTFail("expected thumbnailUnavailable")
        } catch let error as BotPetError {
            XCTAssertEqual(error, .thumbnailUnavailable(slug: "ghost"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testThumbRejectsNonPNGPayload() async throws {
        // A JPEG (or any non-PNG) data URI must be rejected — the PNG
        // bytes must be preserved end-to-end, never silently re-labeled.
        let jpegB64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q=="
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "pet.thumb" {
                    return [Self.responseFrame(id: id, resultObject:
                        #"{"ok":true,"slug":"x","dataUri":"data:image/jpeg;base64,\#(jpegB64)"}"#)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        let client = GatewayBotModeClient(
            gatewayID: GatewayID(rawValue: "g1"), transport: transport)
        do {
            _ = try await client.petThumbnail(profile: "p", slug: "x", sourceURL: nil)
            XCTFail("expected malformed for a JPEG payload")
        } catch let error as BotPetError {
            if case .malformed = error {} else {
                XCTFail("expected malformed, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - unsupported vs transient

    func testMethodNotFoundMapsToPetsUnavailableNotTransient() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "pet.gallery" || method == "pet.thumb" {
                    return [Self.errorFrame(id: id, code: -32601, message: "method not found")]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        let client = GatewayBotModeClient(
            gatewayID: GatewayID(rawValue: "g1"), transport: transport)

        // Capability gap → petsUnavailable (NOT a transient failure).
        do {
            _ = try await client.petGallery(profile: "p", localOnly: false)
            XCTFail("expected petsUnavailable")
        } catch let error as BotPetError {
            if case .petsUnavailable = error {} else {
                XCTFail("expected petsUnavailable, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        do {
            _ = try await client.petThumbnail(profile: "p", slug: "x", sourceURL: nil)
            XCTFail("expected petsUnavailable")
        } catch let error as BotPetError {
            if case .petsUnavailable = error {} else {
                XCTFail("expected petsUnavailable, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testTransientRPCFailureStaysRetryable() async throws {
        // A 5031 (pet failure) is a transient rpcFailed — the caller keeps
        // the retry affordance; the two classes never conflate.
        let log = RequestLog()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frame in
                log.record(frame)
                guard let (id, method) = Self.extractRequest(frame) else { return [] }
                if method == "pet.gallery" {
                    // Fail once transiently, then succeed.
                    if log.params(of: "pet.gallery").count <= 1 {
                        return [Self.errorFrame(id: id, code: 5031, message: "manifest fetch failed")]
                    }
                    return [Self.responseFrame(id: id, resultObject: Self.galleryResult)]
                }
                return []
            }
        )
        let server = try InProcessWebSocketServer(script: script)
        try await server.start()
        defer { server.stop() }
        let transport = makeTransport(serverPort: server.listeningPort)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }
        let client = GatewayBotModeClient(
            gatewayID: GatewayID(rawValue: "g1"), transport: transport)

        do {
            _ = try await client.petGallery(profile: "p", localOnly: false)
            XCTFail("expected transient failure on first call")
        } catch let error as BotModeProfileError {
            if case .rpcFailed = error {} else {
                XCTFail("expected rpcFailed, got \(error)")
            }
        }
        // Retry succeeds — the failure was transient, not a capability fact.
        let gallery = try await client.petGallery(profile: "p", localOnly: false)
        XCTAssertEqual(gallery.pets.count, 3)
    }
}
