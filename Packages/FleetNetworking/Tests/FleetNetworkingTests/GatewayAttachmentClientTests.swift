import XCTest
import FleetCore
@testable import FleetNetworking

/// R10-T1: `GatewayAttachmentClient` — attachment staging over the
/// conversation transport, against an in-process fixture server. Wire shapes
/// verified against hermes-agent 0.21.0 installed source
/// (`~/.hermes/hermes-agent/tui_gateway/methods_prompt.py` + `server.py`):
/// - `file.attach` (methods_prompt.py:1350-1395): params
///   `{session_id, path?, data_url?, name?}` — `data_url` is a
///   `data:<mime>;base64,<b64>` upload, REQUIRED for remote gateways (the
///   path only exists on the client's disk). Result
///   `{attached: true, name, path, ref_path, ref_text: "@file:...",
///   uploaded: bool}` via `_stage_session_file_attachment`
///   (server.py:14506+) + `_attachment_ref_path` (server.py:14416).
/// - `image.attach_bytes` (methods_prompt.py:1163-1222): params
///   `{session_id, content_base64|data, filename?, ext?}` — accepts a
///   `data:image/...;base64,` prefix (`_decode_attach_base64`,
///   server.py:14298, mime_prefix="image/"). Result mirrors `image.attach`:
///   `{attached, path, count, remainder, text, bytes, name?, width?,
///   height?, token_estimate?}` (`_image_meta` server.py:3140-3151).
/// - `pdf.attach` (methods_prompt.py:1224-1348): params
///   `{session_id, content_base64|data, filename?}` — renders pages to PNG
///   via pdftoppm; result `{attached, filename, pages_attached,
///   pages: [{path, page, name?, width?, height?}], count, text}`.
/// - `image.detach` (methods_prompt.py:1397-1412): params
///   `{session_id, path}` → `{detached: bool, count}`.
/// - Error codes: 4015 param missing, 4016 not-found/unsupported ext, 4017
///   invalid base64, 4018 over cap (25 MB images server.py:14284 / 50 MB PDFs
///   server.py:14285 / 25 pages server.py:14286), 5027 write failed, 5028
///   pdf pipeline failure.
final class GatewayAttachmentClientTests: XCTestCase {

    // MARK: helpers

    private func makeTransport(
        serverPort: UInt16,
        requestTimeout: Duration = .seconds(2)
    ) -> GatewayWebSocketTransport {
        let base = URL(string: "http://127.0.0.1:\(serverPort)")!
        let config = TransportConfiguration(
            pingInterval: .seconds(30),
            inboundDeadline: .seconds(30),
            connectTimeout: .seconds(10),
            requestTimeout: requestTimeout
        )
        return GatewayWebSocketTransport(
            baseURL: base,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture-ticket", ttlSeconds: 30)),
            configuration: config
        )
    }

    private static func frame(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private static func readyFrame() -> String {
        frame([
            "jsonrpc": "2.0", "method": "event",
            "params": [
                "type": "gateway.ready",
                "payload": ["change_events": true, "heartbeat": false, "replay_epoch": "epoch-1"],
            ] as [String: Any],
        ])
    }

    private static func extractRequest(_ frameText: String) -> (id: String, method: String, params: [String: Any])? {
        guard let data = frameText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String else { return nil }
        return (id, method, obj["params"] as? [String: Any] ?? [:])
    }

    private static func responseFrame(id: String, result: [String: Any]) -> String {
        frame(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func errorFrame(id: String, code: Int, message: String) -> String {
        frame(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// PNG magic bytes + IHDR-less minimal payload (the fixture server never
    /// decodes the image; the client must never inspect bytes either).
    private static let pngFixture = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])

    private static func dataURL(mime: String, bytes: Data) -> String {
        "data:\(mime);base64,\(bytes.base64EncodedString())"
    }

    // MARK: 1. file.attach

    func testAttachFileSendsDataURLWithoutPathAndDecodesRefText() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "file.attach" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "attached": true,
                        "name": "notes.md",
                        "path": "/srv/hermes/profiles/default/attachments/notes.md",
                        "ref_path": "attachments/notes.md",
                        "ref_text": "@file:attachments/notes.md",
                        "uploaded": true,
                    ])]
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

        let client = GatewayAttachmentClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let staged = try await client.attachFile(
            sessionID: "s-1",
            name: "notes.md",
            dataURL: Self.dataURL(mime: "text/markdown", bytes: Data("# notes".utf8)))

        // Wire ask: the remote-client path MUST carry data_url (the path only
        // exists on the client's disk — methods_prompt.py:1359-1366 docstring)
        // and MUST NOT send a client-only `path` (the gateway would try to
        // resolve it and 4016/5028 on a nonexistent host path).
        let (method, params) = await captured.last
        XCTAssertEqual(method, "file.attach")
        XCTAssertEqual(params["session_id"] as? String, "s-1")
        XCTAssertEqual(params["name"] as? String, "notes.md")
        XCTAssertNil(params["path"], "remote client must upload data_url, never a client-local path")
        let sentURL = params["data_url"] as? String
        XCTAssertTrue(sentURL?.hasPrefix("data:text/markdown;base64,") == true,
                      "data_url must be the data:<mime>;base64,<b64> upload form")

        // Decoded result: the workspace-relative @file: ref the prompt cites.
        XCTAssertEqual(staged.name, "notes.md")
        XCTAssertEqual(staged.refText, "@file:attachments/notes.md")
        XCTAssertEqual(staged.path, "/srv/hermes/profiles/default/attachments/notes.md")
        XCTAssertEqual(staged.uploaded, true)
    }

    func testAttachFileSurfacesRPCError() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "file.attach" {
                    return [Self.errorFrame(id: id, code: 5028, message: "file not found on gateway and no data_url provided")]
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

        let client = GatewayAttachmentClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.attachFile(
                sessionID: "s-1", name: "x.bin",
                dataURL: Self.dataURL(mime: "application/octet-stream", bytes: Data([0x00])))
            XCTFail("expected rpcFailed")
        } catch let error as AttachmentStagingError {
            guard case .rpcFailed(let message) = error else {
                return XCTFail("expected rpcFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("5028"), "error should carry the gateway code: \(message)")
        }
    }

    func testAttachFileRejectsResultWithoutRefText() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "file.attach" {
                    return [Self.responseFrame(id: id, result: ["attached": true, "name": "notes.md"])]
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

        let client = GatewayAttachmentClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.attachFile(
                sessionID: "s-1", name: "notes.md",
                dataURL: Self.dataURL(mime: "text/markdown", bytes: Data("# x".utf8)))
            XCTFail("expected malformedResponse")
        } catch let error as AttachmentStagingError {
            guard case .malformedResponse(let detail) = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
            XCTAssertTrue(detail.contains("ref_text"), "detail should name the missing key: \(detail)")
        }
    }

    // MARK: 2. image.attach_bytes

    func testAttachImageBytesSendsDataURLAsContentBase64AndDecodes() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "image.attach_bytes" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "attached": true,
                        "path": "/srv/hermes/images/upload_20260904_120000_1.png",
                        "count": 1,
                        "remainder": "",
                        "text": "[User attached image: upload_20260904_120000_1.png]",
                        "bytes": Self.pngFixture.count,
                        "name": "upload_20260904_120000_1.png",
                        "width": 64,
                        "height": 64,
                        "token_estimate": 320,
                    ])]
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

        let client = GatewayAttachmentClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let staged = try await client.attachImageBytes(
            sessionID: "s-1",
            filename: "photo.png",
            dataURL: Self.dataURL(mime: "image/png", bytes: Self.pngFixture))

        // Wire ask: `content_base64` is the param key (methods_prompt.py:1181);
        // the value may carry the data:image/...;base64, prefix
        // (_decode_attach_base64 strips it, server.py:14298-14316).
        let (method, params) = await captured.last
        XCTAssertEqual(method, "image.attach_bytes")
        XCTAssertEqual(params["session_id"] as? String, "s-1")
        XCTAssertEqual(params["filename"] as? String, "photo.png")
        let sentB64 = params["content_base64"] as? String
        XCTAssertTrue(sentB64?.hasPrefix("data:image/png;base64,") == true,
                      "the data-URL form is accepted and keeps the image/* mime required by the decoder regex")

        // Decoded result mirrors image.attach (methods_prompt.py:1216-1221).
        XCTAssertEqual(staged.path, "/srv/hermes/images/upload_20260904_120000_1.png")
        XCTAssertEqual(staged.name, "upload_20260904_120000_1.png")
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(staged.byteCount, Self.pngFixture.count)
        XCTAssertEqual(staged.width, 64)
        XCTAssertEqual(staged.height, 64)
    }

    func testAttachImageBytesMapsTooLargeErrorCode() async throws {
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, _) = Self.extractRequest(frameText) else { return [] }
                if method == "image.attach_bytes" {
                    // server.py:14284 caps image bytes at 25 MB → 4018.
                    return [Self.errorFrame(id: id, code: 4018, message: "image too large (26214400 bytes; cap is 25 MB)")]
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

        let client = GatewayAttachmentClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        do {
            _ = try await client.attachImageBytes(
                sessionID: "s-1", filename: "big.png",
                dataURL: Self.dataURL(mime: "image/png", bytes: Self.pngFixture))
            XCTFail("expected tooLarge")
        } catch let error as AttachmentStagingError {
            guard case .tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }

    // MARK: 3. pdf.attach

    func testAttachPDFSendsContentBase64AndDecodesPages() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "pdf.attach" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: [
                        "attached": true,
                        "filename": "report.pdf",
                        "pages_attached": 2,
                        "pages": [
                            ["path": "/srv/hermes/images/pdf_p1_1.png", "page": 1,
                             "name": "pdf_p1_1.png", "width": 1275, "height": 1650],
                            ["path": "/srv/hermes/images/pdf_p2_2.png", "page": 2,
                             "name": "pdf_p2_2.png", "width": 1275, "height": 1650],
                        ],
                        "count": 2,
                        "text": "[User attached PDF: report.pdf (2 page(s))]",
                    ])]
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

        let client = GatewayAttachmentClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let pdf = Data("%PDF-1.4\n%fixture\n".utf8)
        let staged = try await client.attachPDF(
            sessionID: "s-1",
            filename: "report.pdf",
            dataURL: Self.dataURL(mime: "application/pdf", bytes: pdf))

        // Wire ask: content_base64 with the data:application/pdf;base64,
        // prefix (the decoder regex pins mime_prefix="application/pdf",
        // methods_prompt.py:1263).
        let (method, params) = await captured.last
        XCTAssertEqual(method, "pdf.attach")
        XCTAssertEqual(params["session_id"] as? String, "s-1")
        XCTAssertEqual(params["filename"] as? String, "report.pdf")
        let sentB64 = params["content_base64"] as? String
        XCTAssertTrue(sentB64?.hasPrefix("data:application/pdf;base64,") == true,
                      "pdf.attach decodes with mime_prefix=application/pdf — the prefix must match")

        // Decoded result (methods_prompt.py:1335-1347).
        XCTAssertEqual(staged.filename, "report.pdf")
        XCTAssertEqual(staged.pagesAttached, 2)
        XCTAssertEqual(staged.pages.count, 2)
        XCTAssertEqual(staged.pages[0].pageNumber, 1)
        XCTAssertEqual(staged.pages[1].path, "/srv/hermes/images/pdf_p2_2.png")
    }

    // MARK: 4. image.detach

    func testDetachImageSendsPathAndDecodesCount() async throws {
        let captured = ManagementParamCapture()
        let script = InProcessWebSocketServer.Script(
            onOpen: [Self.readyFrame()],
            onText: { frameText in
                guard let (id, method, params) = Self.extractRequest(frameText) else { return [] }
                if method == "image.detach" {
                    captured.record(method, params)
                    return [Self.responseFrame(id: id, result: ["detached": true, "count": 0])]
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

        let client = GatewayAttachmentClient(
            gatewayID: GatewayID(rawValue: "workstation"), transport: transport)
        let state = try await client.detachImage(
            sessionID: "s-1", path: "/srv/hermes/images/upload_20260904_120000_1.png")

        let (method, params) = await captured.last
        XCTAssertEqual(method, "image.detach")
        XCTAssertEqual(params["session_id"] as? String, "s-1")
        XCTAssertEqual(params["path"] as? String, "/srv/hermes/images/upload_20260904_120000_1.png")
        XCTAssertEqual(state.detached, true)
        XCTAssertEqual(state.count, 0)
    }
}
