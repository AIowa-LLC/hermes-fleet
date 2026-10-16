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
        /// Delay between chunks; > 0 delivers on a background queue so a
        /// cancelled transfer can be observed to stop early.
        nonisolated(unsafe) static var chunkDelayMs = 0
        nonisolated(unsafe) static var stoppedEarly = false
        private let stopLock = NSLock()
        private var stopped = false
        private var isStopped: Bool { stopLock.lock(); defer { stopLock.unlock() }; return stopped }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {
            stopLock.lock(); stopped = true; stopLock.unlock()
        }
        override func startLoading() {
            var headers: [String: String] = [:]
            if let declared = Self.declaredLength { headers["Content-Length"] = String(declared) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Self.deliveredChunks = 0
            Self.stoppedEarly = false
            let delayMs = Self.chunkDelayMs
            let deliver = { [self] in
                for _ in 0..<Self.chunkCount {
                    if isStopped { Self.stoppedEarly = true; return }
                    Self.deliveredChunks += 1
                    client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: Self.chunkSize))
                    if delayMs > 0 { Thread.sleep(forTimeInterval: Double(delayMs) / 1000) }
                }
                client?.urlProtocolDidFinishLoading(self)
            }
            if delayMs > 0 { DispatchQueue.global().async(execute: deliver) } else { deliver() }
        }
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkedURLProtocol.self]
        return URLSession(configuration: config)
    }

    private let request = URLRequest(url: URL(string: "https://example.test/x")!)

    func testSmallBodyIsReturnedIntact() async throws {
        ChunkedURLProtocol.chunkDelayMs = 0
        ChunkedURLProtocol.chunkCount = 2
        ChunkedURLProtocol.chunkSize = 100
        ChunkedURLProtocol.declaredLength = 200
        let (data, _) = try await session().boundedData(for: request, limit: 1_000)
        XCTAssertEqual(data.count, 200)
    }

    func testOversizedStreamIsCutOffAndReportedOverLimit() async throws {
        ChunkedURLProtocol.chunkDelayMs = 0
        ChunkedURLProtocol.chunkCount = 50
        ChunkedURLProtocol.chunkSize = 100
        ChunkedURLProtocol.declaredLength = nil // no Content-Length: discovered mid-stream
        let (data, _) = try await session().boundedData(for: request, limit: 1_000)
        XCTAssertEqual(data.count, 1_001, "over-limit body is replaced by a limit+1 marker")
    }

    func testDeclaredOversizeIsRejectedWithoutReadingBody() async throws {
        ChunkedURLProtocol.chunkDelayMs = 0
        ChunkedURLProtocol.chunkCount = 1
        ChunkedURLProtocol.chunkSize = 10
        ChunkedURLProtocol.declaredLength = 5_000_000
        let (data, _) = try await session().boundedData(for: request, limit: 1_000)
        XCTAssertEqual(data.count, 1_001)
    }

    func testOversizedTransferIsActuallyCancelledBeforeTheRestIsDelivered() async throws {
        ChunkedURLProtocol.chunkDelayMs = 5
        ChunkedURLProtocol.chunkCount = 400
        ChunkedURLProtocol.chunkSize = 100
        ChunkedURLProtocol.declaredLength = nil
        let (data, _) = try await session().boundedData(for: request, limit: 1_000)
        XCTAssertEqual(data.count, 1_001)
        // Give the loader a moment to observe the cancellation.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(ChunkedURLProtocol.stoppedEarly, "the transfer must stop, not run to completion")
        XCTAssertLessThan(ChunkedURLProtocol.deliveredChunks, 400)
    }

    func testBodyExactlyAtLimitPassesAndOneByteOverIsRejected() async throws {
        ChunkedURLProtocol.chunkDelayMs = 0
        ChunkedURLProtocol.chunkCount = 1
        ChunkedURLProtocol.declaredLength = nil
        ChunkedURLProtocol.chunkSize = 1_000
        let (exact, _) = try await session().boundedData(for: request, limit: 1_000)
        XCTAssertEqual(exact, Data(repeating: 0x61, count: 1_000))
        ChunkedURLProtocol.chunkSize = 1_001
        let (over, _) = try await session().boundedData(for: request, limit: 1_000)
        XCTAssertEqual(over, Data(count: 1_001), "over-limit body is replaced by the zero marker")
    }
}
