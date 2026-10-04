import XCTest
import UIKit
import FleetCore
@testable import FleetUI

/// Untrusted image bytes must be bounded by pixels (decode) and by aggregate
/// bytes (retention), not only by per-artifact download size.
@MainActor
final class ImageMemoryBoundsTests: XCTestCase {
    private let gateway = GatewayID(rawValue: "workstation")

    private static func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .pngData { ctx in
                UIColor.red.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
    }

    func testPixelBudgetUsesDivisionAndRejectsHostileDimensions() {
        XCTAssertTrue(BoundedImageDecoder.isWithinBudget(width: 4000, height: 3000))
        XCTAssertFalse(BoundedImageDecoder.isWithinBudget(width: 20_000, height: 20_000))
        XCTAssertFalse(BoundedImageDecoder.isWithinBudget(width: Int.max, height: Int.max))
    }

    func testDecodeRefusesOverBudgetAndReportsHeaderSize() {
        let data = Self.png(width: 64, height: 32)
        let size = BoundedImageDecoder.pixelSize(of: data)
        XCTAssertEqual(size?.width, 64)
        XCTAssertEqual(size?.height, 32)
        XCTAssertNotNil(BoundedImageDecoder.decode(data))
        XCTAssertNil(BoundedImageDecoder.decode(data, maxPixels: 64 * 32 - 1))
    }

    func testDecodeCapsLongestEdgeWithoutUpscaling() throws {
        let big = try XCTUnwrap(BoundedImageDecoder.decode(
            Self.png(width: 400, height: 100), maxDimension: 200))
        XCTAssertLessThanOrEqual(max(big.size.width, big.size.height), 200)
        let small = try XCTUnwrap(BoundedImageDecoder.decode(
            Self.png(width: 40, height: 10), maxDimension: 200))
        XCTAssertEqual(small.size.width, 40)
    }

    func testDecodeRejectsNonImageData() {
        XCTAssertNil(BoundedImageDecoder.decode(Data("not an image".utf8)))
    }

    private final class Retriever: ArtifactRetrieving, @unchecked Sendable {
        let gatewayID: GatewayID
        let data: Data
        init(gatewayID: GatewayID, data: Data) { self.gatewayID = gatewayID; self.data = data }
        func retrieve(_ reference: ArtifactReference) async throws -> RetrievedArtifact {
            RetrievedArtifact(reference: reference, data: data, mimeType: "application/octet-stream")
        }
    }

    func testStoreEvictsOldestWhenAggregateBytesExceedCap() async {
        let store = ArtifactImageStore()
        // Each payload is a third of the cap plus one byte, so only two fit.
        let chunk = Data(count: ArtifactImageStore.maxLoadedBytes / 3 + 1)
        let retriever = Retriever(gatewayID: gateway, data: chunk)
        let refs = (0..<3).map {
            ArtifactReference(gatewayID: gateway, sessionID: "s", profile: "default", path: "/x/\($0).bin")
        }
        for ref in refs { _ = await store.load(ref, using: retriever) }
        XCTAssertNil(store.state(for: refs[0]), "oldest payload is evicted to honor the byte cap")
        XCTAssertNotNil(store.state(for: refs[1]))
        XCTAssertNotNil(store.state(for: refs[2]))
    }

    // MARK: picker size cap before materialization

    private func tempFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-\(UUID().uuidString).bin")
        try Data(count: bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testBoundedFileReadsWithinLimit() throws {
        let url = try tempFile(bytes: 100)
        XCTAssertEqual(try BoundedPickedFile.read(url, limit: 100).count, 100)
    }

    func testBoundedFileRefusesOversizeWithoutReading() throws {
        let url = try tempFile(bytes: 101)
        XCTAssertThrowsError(try BoundedPickedFile.read(url, limit: 100)) { error in
            XCTAssertEqual((error as? BoundedPickedFile.TooLarge)?.sizeBytes, 101)
        }
    }

    func testBoundedFileSizeFailsClosedForMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try BoundedPickedFile.size(of: url))
    }
}
