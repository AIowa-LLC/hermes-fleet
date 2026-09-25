import XCTest
import CryptoKit
import FleetCore
import FleetNetworking

/// Card C — ENVIRONMENTAL live check (opt-in): proves the real
/// `GatewayArtifactClient` retrieves REAL image bytes from a running Hermes
/// gateway through the authenticated `/api/media` contract, and that the
/// auth / root-confinement / expiration classifications hold on the wire.
///
/// Skipped unless `FLEET_LIVE_ARTIFACT_*` env vars are present, so CI stays
/// hermetic. Driven by `scripts/c_artifact_live_check.sh`, which supplies:
/// - `FLEET_LIVE_ARTIFACT_BASE_URL`      dashboard base (e.g. http://127.0.0.1:18923)
/// - `FLEET_LIVE_ARTIFACT_TOKEN_FILE`    file holding the session token
/// - `FLEET_LIVE_ARTIFACT_PATH`          gateway-local image path (media root)
/// - `FLEET_LIVE_ARTIFACT_SHA256`        sha256 of that file, computed host-side
/// - `FLEET_LIVE_ARTIFACT_MISSING_PATH`  a media-root path that does not exist
/// - `FLEET_LIVE_ARTIFACT_OUTSIDE_PATH`  an image-suffixed path outside the roots
/// - `FLEET_LIVE_ARTIFACT_EVIDENCE_OUT`  where to write the evidence JSON
final class ArtifactTransportLiveCheck: XCTestCase {

    private struct LiveConfig {
        let baseURL: URL
        let token: String
        let artifactPath: String
        let expectedSHA256: String?
        let missingPath: String?
        let outsideRootsPath: String?
        let evidenceOut: String?
    }

    private func liveConfig() throws -> LiveConfig {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["FLEET_LIVE_ARTIFACT_BASE_URL"], let url = URL(string: base),
              let tokenFile = env["FLEET_LIVE_ARTIFACT_TOKEN_FILE"],
              let artifactPath = env["FLEET_LIVE_ARTIFACT_PATH"] else {
            throw XCTSkip("live artifact check not configured (set FLEET_LIVE_ARTIFACT_* env)")
        }
        let token = try String(contentsOfFile: tokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw XCTSkip("live artifact token file was empty")
        }
        return LiveConfig(
            baseURL: url,
            token: token,
            artifactPath: artifactPath,
            expectedSHA256: env["FLEET_LIVE_ARTIFACT_SHA256"],
            missingPath: env["FLEET_LIVE_ARTIFACT_MISSING_PATH"],
            outsideRootsPath: env["FLEET_LIVE_ARTIFACT_OUTSIDE_PATH"],
            evidenceOut: env["FLEET_LIVE_ARTIFACT_EVIDENCE_OUT"])
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeClient(_ config: LiveConfig, token: String?) -> GatewayArtifactClient {
        GatewayArtifactClient(
            gatewayID: GatewayID(rawValue: "live-dev-gateway"),
            baseURL: config.baseURL,
            credential: { token.map { .sessionTokenHeader($0) } ?? .none })
    }

    private func reference(_ config: LiveConfig, path: String) -> ArtifactReference {
        ArtifactReference(
            gatewayID: GatewayID(rawValue: "live-dev-gateway"),
            sessionID: "live-check",
            path: path)
    }

    /// One aggregate check so the evidence file always lands, even when an
    /// assertion fails mid-way.
    func testLiveMediaContract() async throws {
        let config = try liveConfig()
        var checks: [[String: Any]] = []

        func record(_ name: String, ok: Bool, detail: Any) {
            checks.append(["name": name, "ok": ok, "detail": detail])
        }

        // 1. REAL BYTES through the authenticated contract.
        do {
            let artifact = try await makeClient(config, token: config.token)
                .retrieve(reference(config, path: config.artifactPath))
            let digest = Self.sha256Hex(artifact.data)
            let sniffed = ArtifactTransportRules.sniffedExtension(for: artifact.data)
            let matchesExpected = config.expectedSHA256.map { $0 == digest } ?? (artifact.byteCount > 0)
            record("live-real-bytes", ok: artifact.byteCount > 0 && matchesExpected, detail: [
                "byte_count": artifact.byteCount,
                "mime_type": artifact.mimeType,
                "sha256": digest,
                "expected_sha256": config.expectedSHA256 ?? "not-provided",
                "sha256_match": matchesExpected,
                "sniffed_extension": sniffed ?? "none",
                "request_endpoint_path": "/api/media",
                "reference_name": artifact.reference.displayName,
            ])
        } catch {
            record("live-real-bytes", ok: false, detail: "\(error)")
        }

        // 2. The same call WITHOUT a credential is rejected (auth is real).
        do {
            _ = try await makeClient(config, token: nil)
                .retrieve(reference(config, path: config.artifactPath))
            record("live-auth-required", ok: false, detail: "unauthenticated fetch unexpectedly succeeded")
        } catch let error as ArtifactTransportError {
            if case .authenticationRequired = error {
                record("live-auth-required", ok: true, detail: "401 -> authenticationRequired")
            } else {
                record("live-auth-required", ok: false, detail: "\(error)")
            }
        } catch {
            record("live-auth-required", ok: false, detail: "\(error)")
        }

        // 3. Client-side traversal guard: refused before any request.
        do {
            _ = try await makeClient(config, token: config.token).retrieve(
                reference(config, path: config.artifactPath + "/../../" + (config.artifactPath as NSString).lastPathComponent))
            record("live-traversal-refused", ok: false, detail: "traversal path was not refused")
        } catch let error as ArtifactTransportError {
            if case .invalidReference = error {
                record("live-traversal-refused", ok: true, detail: "invalidReference (client-side, no request)")
            } else {
                record("live-traversal-refused", ok: false, detail: "\(error)")
            }
        } catch {
            record("live-traversal-refused", ok: false, detail: "\(error)")
        }

        // 4. Server-side root confinement: an image-suffixed path OUTSIDE the
        // media roots is refused by the gateway (403).
        if let outside = config.outsideRootsPath {
            do {
                _ = try await makeClient(config, token: config.token)
                    .retrieve(reference(config, path: outside))
                record("live-outside-roots-blocked", ok: false, detail: "outside-roots fetch unexpectedly succeeded")
            } catch let error as ArtifactTransportError {
                if case .notPermitted = error {
                    record("live-outside-roots-blocked", ok: true, detail: "403 -> notPermitted")
                } else {
                    record("live-outside-roots-blocked", ok: false, detail: "\(error)")
                }
            } catch {
                record("live-outside-roots-blocked", ok: false, detail: "\(error)")
            }
        }

        // 5. Expiration handling: a media-root path that no longer exists is a
        // 404 -> .expired (cache retention is host-side).
        if let missing = config.missingPath {
            do {
                _ = try await makeClient(config, token: config.token)
                    .retrieve(reference(config, path: missing))
                record("live-expired-404", ok: false, detail: "missing path unexpectedly succeeded")
            } catch let error as ArtifactTransportError {
                if case .expired = error, error.isExpiration {
                    record("live-expired-404", ok: true, detail: "404 -> expired (isExpiration)")
                } else {
                    record("live-expired-404", ok: false, detail: "\(error)")
                }
            } catch {
                record("live-expired-404", ok: false, detail: "\(error)")
            }
        }

        // Evidence + verdict.
        let failures = checks.filter { ($0["ok"] as? Bool) != true }.map { $0["name"] as? String ?? "?" }
        let evidence: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "base_url": config.baseURL.absoluteString,
            "checks": checks,
            "verdict": ["all_pass": failures.isEmpty, "failures": failures],
        ]
        if let out = config.evidenceOut,
           let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: out))
        }
        if let summary = String(
            data: (try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])) ?? Data(),
            encoding: .utf8) {
            print("LIVE-EVIDENCE \(summary)")
        }
        XCTAssertTrue(failures.isEmpty, "live artifact checks failed: \(failures)")
    }
}
