import XCTest
import FleetCore
import FleetNetworking

/// Card C — the per-gateway factory's binding + credential behavior.
final class GatewayArtifactRetrievalFactoryTests: XCTestCase {

    private final class StubCredentialStore: CredentialStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: GatewayCredential] = [:]

        init(_ credential: GatewayCredential? = nil, gateway: String = "gw") {
            if let credential { stored[gateway] = credential }
        }

        func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
            lock.withLock { stored[gatewayID.rawValue] = credential }
        }

        func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
            lock.withLock { stored[gatewayID.rawValue] }
        }

        func deleteCredential(for gatewayID: GatewayID) async throws {
            lock.withLock { stored[gatewayID.rawValue] = nil }
        }
    }

    private var stubConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaStubURLProtocol.self]
        return config
    }

    override func setUp() {
        super.setUp()
        MediaStubURLProtocol.capturedRequests = []
        MediaStubURLProtocol.plan = .init()
        MediaStubURLProtocol.didCancel = false
    }

    private func gateway(
        endpoint: URL? = URL(string: "https://gateway.example.invalid:9120"),
        strategy: GatewayAuthConfiguration.Strategy
    ) -> FleetGateway {
        FleetGateway(
            id: GatewayID(rawValue: "gw"),
            displayName: "GW",
            endpoint: endpoint,
            authConfiguration: GatewayAuthConfiguration(strategy: strategy, credentialStored: true))
    }

    private func reference() -> ArtifactReference {
        ArtifactReference(
            gatewayID: GatewayID(rawValue: "gw"),
            path: "/var/cache/images/x.png",
            name: "x.png")
    }

    private static func pngEnvelope() -> Data {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data(repeating: 0x7A, count: 16))
        return Data(#"{"data_url":"data:image/png;base64,\#(png.base64EncodedString())"}"#.utf8)
    }

    func testGatewayWithoutEndpointGetsFailClosedStub() async {
        let retrieval = GatewayArtifactRetrieval.make(
            gateway: gateway(endpoint: nil, strategy: .sessionToken),
            credentialStore: StubCredentialStore())
        XCTAssertTrue(retrieval is UnsupportedArtifactRetrieval)
        do {
            _ = try await retrieval.retrieve(reference())
            XCTFail("expected notConfigured")
        } catch let error as ArtifactTransportError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testSessionTokenStrategySendsStoredCredential() async throws {
        MediaStubURLProtocol.plan.body = Self.pngEnvelope()
        let retrieval = GatewayArtifactRetrieval.make(
            gateway: gateway(strategy: .sessionToken),
            credentialStore: StubCredentialStore(GatewayCredential(rawValue: "stored-token")),
            urlSessionConfiguration: stubConfiguration)

        let artifact = try await retrieval.retrieve(reference())
        XCTAssertEqual(artifact.byteCount, 24)

        let request = try XCTUnwrap(MediaStubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "stored-token")
        XCTAssertEqual(request.url?.path, "/api/media")
    }

    func testMissingCredentialFailsBeforeAnyRequest() async {
        let retrieval = GatewayArtifactRetrieval.make(
            gateway: gateway(strategy: .sessionToken),
            credentialStore: StubCredentialStore(),
            urlSessionConfiguration: stubConfiguration)
        do {
            _ = try await retrieval.retrieve(reference())
            XCTFail("expected authenticationRequired")
        } catch let error as ArtifactTransportError {
            guard case .authenticationRequired = error else {
                return XCTFail("unexpected \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(MediaStubURLProtocol.capturedRequests.isEmpty)
    }

    func testNoneStrategyIssuesAnonymousRequest() async throws {
        MediaStubURLProtocol.plan.body = Self.pngEnvelope()
        let retrieval = GatewayArtifactRetrieval.make(
            gateway: gateway(strategy: .none),
            credentialStore: StubCredentialStore(),
            urlSessionConfiguration: stubConfiguration)

        _ = try await retrieval.retrieve(reference())
        let request = try XCTUnwrap(MediaStubURLProtocol.capturedRequests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testRetrieverStaysBoundToItsGateway() async {
        let retrieval = GatewayArtifactRetrieval.make(
            gateway: gateway(strategy: .none),
            credentialStore: StubCredentialStore(),
            urlSessionConfiguration: stubConfiguration)
        let foreign = ArtifactReference(
            gatewayID: GatewayID(rawValue: "other"),
            path: "/var/cache/images/x.png")
        do {
            _ = try await retrieval.retrieve(foreign)
            XCTFail("expected gatewayMismatch")
        } catch let error as ArtifactTransportError {
            guard case .gatewayMismatch = error else {
                return XCTFail("unexpected \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(MediaStubURLProtocol.capturedRequests.isEmpty)
    }
}
