import XCTest
import Security
@testable import FleetCore
@testable import FleetNetworking

/// End to end: this app's pairing client against the REAL gateway pairing code (the
/// `feature/fleet-device-pairing` branch of hermes-agent) over a real TLS connection.
///
/// Skipped unless both are set, so it never runs against anything but a throwaway local server:
///   FLEET_PAIRING_E2E_SERVER=/path/to/hermes-agent-fleet-pairing
///   FLEET_PAIRING_E2E_PYTHON=/path/to/python (3.11 with fastapi/uvicorn/httpx)
/// The server (`scripts/fleet_pairing_dev_server.py`) uses a temporary Hermes home, a certificate
/// generated for the run and a throwaway owner login; it touches no real gateway or credential.
final class PairingGatewayE2ETests: XCTestCase {
    private static var serverDir: String? { ProcessInfo.processInfo.environment["FLEET_PAIRING_E2E_SERVER"] }
    private static var python: String? { ProcessInfo.processInfo.environment["FLEET_PAIRING_E2E_PYTHON"] }

    private var process: Process!
    private var origin: URL!
    private var ownerPassword = ""
    private var anchor: SecCertificate!

    /// Boot per test class instance lazily.
    private func boot(ttl: Int? = nil) throws {
        guard let serverDir = Self.serverDir, let python = Self.python, !serverDir.isEmpty, !python.isEmpty else {
            throw XCTSkip("FLEET_PAIRING_E2E_SERVER / FLEET_PAIRING_E2E_PYTHON not set")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        var args = ["\(serverDir)/scripts/fleet_pairing_dev_server.py"]
        if let ttl { args += ["--ttl", "\(ttl)"] }
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: serverDir)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["HERMES_HOME"] = NSTemporaryDirectory() + "fleet-e2e-boot-\(UUID().uuidString)"
        env["PYTHONPATH"] = serverDir
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        addTeardownBlock { [process] in
            process.terminate()
            process.waitUntilExit()
        }
        // First stdout line is a JSON object describing the server.
        var buffer = Data()
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.1); continue }
            buffer.append(chunk)
            if buffer.contains(UInt8(ascii: "\n")) { break }
        }
        let newline = UInt8(ascii: "\n")
        let line: Data
        if let newlineIndex = buffer.firstIndex(of: newline) {
            line = Data(buffer[..<newlineIndex])
        } else {
            line = Data()
        }
        guard let info = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let originText = info["origin"] as? String, let url = URL(string: originText),
              let password = info["owner_password"] as? String, let certPath = info["cert"] as? String,
              let pem = try? String(contentsOfFile: certPath, encoding: .utf8) else {
            throw NSError(domain: "PairingGatewayE2ETests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "dev gateway did not start"])
        }
        origin = url
        ownerPassword = password
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw NSError(domain: "PairingGatewayE2ETests", code: 2)
        }
        anchor = certificate
    }

    // MARK: owner (a signed-in dashboard session, as the CLI/browser would be)

    private final class OwnerDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        let trust: AnchoredTrust
        init(trust: AnchoredTrust) { self.trust = trust }
        func urlSession(
            _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if let serverTrust = challenge.protectionSpace.serverTrust,
               trust.isTrusted(serverTrust, host: challenge.protectionSpace.host) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    private var ownerSession: URLSession!

    private func signInOwner() async throws {
        let config = URLSessionConfiguration.ephemeral
        ownerSession = URLSession(
            configuration: config, delegate: OwnerDelegate(trust: AnchoredTrust(anchors: [anchor])),
            delegateQueue: nil)
        let (data, response) = try await send("POST", "/auth/password-login", [
            "provider": "owner", "username": "owner", "password": ownerPassword])
        XCTAssertEqual(response.statusCode, 200, "owner sign-in: \(String(decoding: data.prefix(200), as: UTF8.self))")
    }

    @discardableResult
    private func send(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: origin.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await ownerSession.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    private func issueInvitation(label: String = "e2e") async throws -> (link: PairingInvitationLink, id: String) {
        let (data, response) = try await send("POST", "/api/fleet/pairing/invitations", ["label": label])
        XCTAssertEqual(response.statusCode, 201)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = try XCTUnwrap(json["link"] as? String)
        return (try PairingInvitationLink.parseForTesting(text), try XCTUnwrap(json["id"] as? String))
    }

    private func client() -> GatewayPairingClient { GatewayPairingClient(trust: AnchoredTrust(anchors: [anchor])) }

    // MARK: the real exchange

    func testPreviewRedeemReplayAndRevocationAgainstTheRealGateway() async throws {
        try boot()
        try await signInOwner()
        let (link, _) = try await issueInvitation(label: "Tony's phone")
        XCTAssertEqual(link.origin.host, "localhost")

        let preview = try await client().preview(link)
        XCTAssertEqual(preview.gateway.displayName, "Dev Gateway")
        XCTAssertEqual(preview.gateway.instanceID.count, 32)
        XCTAssertEqual(preview.access.map(\.scope), ["fleet:operator"])
        XCTAssertEqual(preview.label, "Tony's phone")
        XCTAssertEqual(preview.expiresAt.timeIntervalSinceNow, 600, accuracy: 15)
        // Previewing again changes nothing: the invitation is still unused.
        _ = try await client().preview(link)

        let grant = try await client().redeem(link, deviceName: "E2E iPhone", expecting: preview)
        XCTAssertEqual(grant.gateway.instanceID, preview.gateway.instanceID)
        XCTAssertTrue(grant.credential.rawValue.hasPrefix("hfd1."))
        XCTAssertEqual(grant.tlsFingerprint, preview.tlsFingerprint)

        // Replay and re-preview of a used link fail clearly.
        do { _ = try await client().redeem(link, deviceName: "again", expecting: preview); XCTFail() }
        catch { XCTAssertEqual(error, .alreadyUsed) }
        do { _ = try await client().preview(link); XCTFail() }
        catch { XCTAssertEqual(error, .alreadyUsed) }

        // The device is listed for the owner and its credential logs in.
        let (devices, _) = try await send("GET", "/api/fleet/devices")
        XCTAssertTrue(String(decoding: devices, as: UTF8.self).contains("E2E iPhone"))
        let login = try await deviceLogin(grant.credential.rawValue)
        XCTAssertEqual(login.status, 200)
        XCTAssertEqual(login.cookie?.name, "__Host-hermes_session_at", "real wire cookie name")

        // Revoke from the phone: the gateway confirms, then no longer knows the credential.
        let first = await client().revoke(origin: origin, credential: grant.credential)
        XCTAssertEqual(first, .revoked)
        let second = await client().revoke(origin: origin, credential: grant.credential)
        XCTAssertEqual(second, .alreadyRevoked)
        let after = try await deviceLogin(grant.credential.rawValue)
        XCTAssertEqual(after.status, 401, "a revoked device can no longer sign in")
    }

    func testSimultaneousRedemptionHasExactlyOneWinnerAgainstTheRealGateway() async throws {
        try boot()
        try await signInOwner()
        let (link, _) = try await issueInvitation()
        let preview = try await client().preview(link)

        let anchors = [anchor!]
        let results = await withTaskGroup(of: Result<PairingGrant, PairingFailure>.self) { group in
            for name in ["A", "B", "C"] {
                group.addTask {
                    do throws(PairingFailure) {
                        return .success(try await GatewayPairingClient(trust: AnchoredTrust(anchors: anchors))
                            .redeem(link, deviceName: name, expecting: preview))
                    } catch { return .failure(error) }
                }
            }
            var all: [Result<PairingGrant, PairingFailure>] = []
            for await result in group { all.append(result) }
            return all
        }
        let wins = results.filter { if case .success = $0 { return true } else { return false } }
        let losses = results.compactMap { r -> PairingFailure? in if case .failure(let f) = r { return f } else { return nil } }
        XCTAssertEqual(wins.count, 1)
        XCTAssertEqual(losses, [.alreadyUsed, .alreadyUsed])
        let (devices, _) = try await send("GET", "/api/fleet/devices")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: devices) as? [String: Any])
        XCTAssertEqual((json["devices"] as? [Any])?.count, 1, "only one device was created")
    }

    func testOwnerCancellationAndWrongSecretsAgainstTheRealGateway() async throws {
        try boot()
        try await signInOwner()
        let (link, id) = try await issueInvitation()
        let preview = try await client().preview(link)

        let (_, cancelled) = try await send("DELETE", "/api/fleet/pairing/invitations/\(id)")
        XCTAssertEqual(cancelled.statusCode, 200)
        do { _ = try await client().redeem(link, deviceName: "x", expecting: preview); XCTFail() }
        catch { XCTAssertEqual(error, .cancelled) }

        let (second, _) = try await issueInvitation()
        let guessed = try PairingInvitationLink.parseForTesting(
            "https://localhost:\(second.origin.port!)/pair#v=1&i=\(second.invitationID)&s=\(String(repeating: "g", count: 43))")
        do { _ = try await client().preview(guessed); XCTFail() }
        catch { XCTAssertEqual(error, .invalidInvitation) }
    }

    func testTheRealGatewayCertificateIsNotTrustedBySystemRoots() async throws {
        try boot()
        try await signInOwner()
        let (link, _) = try await issueInvitation()
        do { _ = try await GatewayPairingClient().preview(link); XCTFail() }
        catch { XCTAssertEqual(error, .untrustedCertificate) }
    }

    func testAnExpiredInvitationAgainstTheRealGateway() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLEET_PAIRING_E2E_SLOW"] == "1",
                          "waits for a real 60 s invitation to expire; set FLEET_PAIRING_E2E_SLOW=1")
        try boot(ttl: 60)
        try await signInOwner()
        let (link, _) = try await issueInvitation()
        _ = try await client().preview(link)
        try await Task.sleep(for: .seconds(62))
        do { _ = try await client().preview(link); XCTFail() }
        catch { XCTAssertEqual(error, .expired) }
    }

    // MARK: raw device login (the app's REST layer uses the same endpoint)

    private func deviceLogin(_ credential: String) async throws -> (status: Int, cookie: SessionCookie?) {
        let session = URLSession(
            configuration: .ephemeral, delegate: OwnerDelegate(trust: AnchoredTrust(anchors: [anchor])),
            delegateQueue: nil)
        var request = URLRequest(url: origin.appendingPathComponent("auth/device-login"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["device_credential": credential])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, PasswordLoginClient.parseSessionCookie(from: http))
    }
}
