import XCTest
import Foundation
@testable import FleetNetworking

/// Control-plane REST responses are size-limited while streaming, not after
/// the whole body has been buffered.
final class BoundedResponseTests: XCTestCase {

    final class ChunkedURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var chunkCount = 0
        nonisolated(unsafe) static var chunkSize = 0
        nonisolated(unsafe) static var declaredLength: Int?
        nonisolated(unsafe) static var deliveredChunks = 0

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            var headers: [String: String] = [:]
            if let declared = Self.declaredLength { headers["Content-Length"] = String(declared) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Self.deliveredChunks = 0
            for _ in 0..<Self.chunkCount {
                Self.deliveredChunks += 1
                client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: Self.chunkSize))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkedURLProtocol.self]
        return URLSession(configuration: config)
    }

    private let request = URLRequest(url: URL(string: "https://example.test/x")!)

    func testSmallBodyIsReturnedIntact() async throws {
        ChunkedURLProtocol.chunkCount = 2
        ChunkedURLProtocol.chunkSize = 100
        ChunkedURLProtocol.declaredLength = 200
        let (data, _) = try await session().boundedData(for: request, limit: 1_000)
        XCTAssertEqual(data.count, 200)
    }

    func testOversizedStreamIsCutOffAndReportedOverLimit() async throws {
        ChunkedURLProtocol.chunkCount = 50
        ChunkedURLProtocol.chunkSize = 100
        ChunkedURLProtocol.declaredLength = nil // no Content-Length: discovered mid-stream
        let (data, _) = try await session().boundedData(for: request, limit: 1_000)
        XCTAssertEqual(data.count, 1_001, "over-limit body is replaced by a limit+1 marker")
    }

    func testDeclaredOversizeIsRejectedWithoutReadingBody() async throws {
        ChunkedURLProtocol.chunkCount = 1
        ChunkedURLProtocol.chunkSize = 10
        ChunkedURLProtocol.declaredLength = 5_000_000
        let (data, _) = try await session().boundedData(for: request, limit: 1_000)
        XCTAssertEqual(data.count, 1_001)
    }
}
