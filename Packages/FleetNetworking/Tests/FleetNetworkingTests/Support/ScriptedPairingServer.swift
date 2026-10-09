import Foundation
import Security
import XCTest
@testable import FleetCore
@testable import FleetNetworking

/// A real HTTPS server on loopback (Python standard library, throwaway certificate) that speaks
/// the Add to Fleet wire protocol and can misbehave on demand. It records every request it
/// receives so tests can assert what did - and did not - reach the network.
final class ScriptedPairingServer: @unchecked Sendable {
    enum Behavior: String {
        case ok
        case redirect
        case html          // 200 text/html, like an older gateway's SPA fallback
        case huge          // response body over the client's limit
        case garbage       // 200 with non-pairing JSON
        case wrongOrigin   // identity claims a different origin
        case wrongInstance // redeem reports a different installation
        case badCredential // redeem returns a malformed credential
        case unknownScope  // asks for access the app does not know
        case rotateKey     // serve a different certificate after the first connection
        case expired, alreadyUsed, cancelled, invalid, rateLimited, unavailable, serverError
    }

    struct Seen: Decodable {
        let method: String
        let path: String
        let query: String
        let headers: [String: String]
        let body: String
    }

    let directory: URL
    /// The server's two throwaway certificates (the second is served after a `rotateKey` preview).
    let certificates: [SecCertificate]
    var certificate: SecCertificate { certificates[0] }
    private(set) var port = 0
    private var process: Process?
    private let logURL: URL

    static let python = "/usr/bin/python3"
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: python)
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl")
    }

    init(_ behavior: Behavior) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-pairing-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("requests.jsonl")
        let first = try Self.makeCertificate(in: directory, name: "a")
        let second = try Self.makeCertificate(in: directory, name: "b")
        certificates = [first.certificate, second.certificate]
        let script = directory.appendingPathComponent("server.py")
        try Self.source.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.python)
        process.arguments = [script.path, behavior.rawValue, first.cert.path, first.key.path,
                             second.cert.path, second.key.path, logURL.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        // The server prints its port as the first line.
        let line = out.fileHandleForReading.availableData
        guard let text = String(data: line, encoding: .utf8),
              let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate()
            throw NSError(domain: "ScriptedPairingServer", code: 1)
        }
        port = value
    }

    deinit { stop() }

    func stop() {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        try? FileManager.default.removeItem(at: directory)
    }

    var origin: URL { URL(string: "https://localhost:\(port)")! }

    func link(id: String = "AbCdEfGhIjKlMnOpQrStUv", secret: String = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG") throws
        -> PairingInvitationLink {
        try PairingInvitationLink.parseForTesting("https://localhost:\(port)/pair#v=1&i=\(id)&s=\(secret)")
    }

    var requests: [Seen] {
        guard let data = try? Data(contentsOf: logURL), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Seen.self, from: Data($0.utf8)) }
    }

    /// Trusts exactly this server's throwaway certificates, validated as a normal TLS server
    /// certificate for `localhost` (no "accept anything").
    func trust() -> AnchoredTrust { AnchoredTrust(anchors: certificates) }

    // MARK: certificates

    private static func makeCertificate(in directory: URL, name: String) throws
        -> (cert: URL, key: URL, certificate: SecCertificate) {
        let cert = directory.appendingPathComponent("cert-\(name).pem")
        let key = directory.appendingPathComponent("key-\(name).pem")
        let der = directory.appendingPathComponent("cert-\(name).der")
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path,
                                     "-out", cert.path, "-days", "2", "-subj", "/CN=localhost",
                                     "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
                                     "-addext", "extendedKeyUsage=serverAuth",
                                     "-addext", "basicConstraints=CA:FALSE"])
        try run("/usr/bin/openssl", ["x509", "-in", cert.path, "-outform", "DER", "-out", der.path])
        guard let data = try? Data(contentsOf: der),
              let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw NSError(domain: "ScriptedPairingServer", code: 2)
        }
        return (cert, key, certificate)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: tool, code: Int(process.terminationStatus)) }
        return process.terminationStatus
    }

    // MARK: the server program

    private static let source = #"""
import json, ssl, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

behavior, cert_a, key_a, cert_b, key_b, log_path = sys.argv[1:7]
INSTANCE = "ab12cd34" * 4
OTHER_INSTANCE = "ef56ab78" * 4
DEVICE = "0123abcd" * 4
CREDENTIAL = "hfd1." + DEVICE + "." + "S" * 43
lock = threading.Lock()
rotated = [False]

def log(entry):
    with lock:
        with open(log_path, "a") as f:
            f.write(json.dumps(entry) + "\n")

ctx_a = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx_a.load_cert_chain(cert_a, key_a)
ctx_b = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx_b.load_cert_chain(cert_b, key_b)

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def origin(self): return "https://" + self.headers.get("Host", "")
    def reply(self, status, body, ctype="application/json", extra=None):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length).decode()
        path, _, query = self.path.partition("?")
        if behavior == "rotateKey" and path.endswith("/preview"): rotated[0] = True
        log({"method": "POST", "path": path, "query": query, "body": body,
             "headers": {k.lower(): v for k, v in self.headers.items()}})
        errors = {"expired": (410, "expired"), "alreadyUsed": (409, "already_used"),
                  "cancelled": (410, "cancelled"), "invalid": (404, "invalid"),
                  "rateLimited": (429, "rate_limited"), "unavailable": (409, "pairing_unavailable")}
        if path == "/auth/device-revoke":
            ok = json.loads(body).get("device_credential") == CREDENTIAL
            return self.reply(200 if ok else 401, {"ok": True} if ok else {"error": "invalid_credential"})
        if behavior in errors:
            status, code = errors[behavior]
            return self.reply(status, {"error": code, "detail": "x"})
        if behavior == "serverError": return self.reply(503, b"upstream down", "text/plain")
        if behavior == "redirect":
            return self.reply(307, b"", "text/plain", {"Location": "https://localhost:1/steal"})
        if behavior == "html": return self.reply(200, b"<!doctype html><html></html>", "text/html")
        if behavior == "huge": return self.reply(200, b"{" + b" " * (200 * 1024) + b"}")
        if behavior == "garbage": return self.reply(200, {"hello": "world"})
        origin = self.origin()
        gw = {"instance_id": INSTANCE, "display_name": "Scripted Gateway", "origin": origin}
        if behavior == "wrongOrigin": gw["origin"] = "https://evil.example.test"
        if path.endswith("/preview"):
            scopes = ["fleet:operator", "root:everything"] if behavior == "unknownScope" else ["fleet:operator"]
            req = json.loads(body)
            return self.reply(200, {"gateway": gw, "invitation": {
                "id": req.get("invitation_id"), "label": "Tony's phone", "scopes": scopes,
                "expires_at": 1000600, "server_time": 1000000}, "access": []})
        if path.endswith("/redeem"):
            if behavior == "wrongInstance": gw["instance_id"] = OTHER_INSTANCE
            cred = "not-a-credential" if behavior == "badCredential" else CREDENTIAL
            return self.reply(201, {"device": {"id": DEVICE, "label": "iPhone"}, "credential": cred,
                                    "gateway": gw, "scopes": ["fleet:operator"]})
        return self.reply(404, {"error": "invalid"})

class Server(ThreadingHTTPServer):
    daemon_threads = True
    def get_request(self):
        sock, addr = self.socket.accept()
        use_b = behavior == "rotateKey" and rotated[0]
        try:
            return (ctx_b if use_b else ctx_a).wrap_socket(sock, server_side=True), addr
        except Exception:
            sock.close(); raise

server = Server(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
"""#
}

/// Trusts only the given anchor certificate, but still performs real TLS server-certificate
/// validation against it (chain, hostname `localhost`, validity, key usage).
struct AnchoredTrust: PairingTrustEvaluating {
    let anchors: [SecCertificate]

    func isTrusted(_ trust: SecTrust, host: String) -> Bool {
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess else { return false }
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}
