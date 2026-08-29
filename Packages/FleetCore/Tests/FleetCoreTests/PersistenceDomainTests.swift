import XCTest
import os
import FleetCore

/// M10 persistence/cache domain values: `StoredToken` redaction (a secret
/// never prints), `TokenStoreError` / `CacheStoreError` vocabulary (no secret
/// material in errors), and the seam protocols' construction.
final class PersistenceDomainTests: XCTestCase {

    // MARK: StoredToken — redaction (spec §27/§29, synthesis §12)

    func testStoredTokenDescriptionIsRedacted() {
        let token = StoredToken(rawValue: "super-secret-ticket-value")
        XCTAssertEqual(token.description, "[REDACTED]")
        XCTAssertEqual(token.debugDescription, "StoredToken(redacted)")
        XCTAssertFalse(token.description.contains("secret"), "raw value never prints")
        XCTAssertFalse("\(token)".contains("super-secret"), "interpolation never prints")
    }

    func testStoredTokenEquality() {
        XCTAssertEqual(StoredToken(rawValue: "a"), StoredToken(rawValue: "a"))
        XCTAssertNotEqual(StoredToken(rawValue: "a"), StoredToken(rawValue: "b"))
    }

    // MARK: TokenStoreError — no secret material

    func testTokenStoreErrorVocabulary() {
        XCTAssertEqual(TokenStoreError.itemNotFound, .itemNotFound)
        XCTAssertEqual(TokenStoreError.malformedData, .malformedData)
        XCTAssertEqual(TokenStoreError.unexpectedStatus(0), .unexpectedStatus(0))
        XCTAssertEqual(TokenStoreError.storeUnavailable("x"), .storeUnavailable("x"))
        XCTAssertNotNil(TokenStoreError.itemNotFound.errorDescription)
        // Errors must not carry raw secret text by construction (only numeric
        // OSStatus / a caller-provided non-secret detail).
        XCTAssertTrue(TokenStoreError.unexpectedStatus(253).errorDescription?.contains("253") == true)
    }

    // MARK: CacheStoreError — no secret material

    func testCacheStoreErrorVocabulary() {
        XCTAssertEqual(CacheStoreError.storeUnavailable("x"), .storeUnavailable("x"))
        XCTAssertEqual(CacheStoreError.malformedData("y"), .malformedData("y"))
        XCTAssertEqual(CacheStoreError.unsupported, .unsupported)
        XCTAssertNotNil(CacheStoreError.unsupported.errorDescription)
    }

    // MARK: Seam construction (protocols are Sendable-typed, no secret params)

    func testTokenStoringIsSendableTypedSeam() async throws {
        // The seam is Sendable and exposes no secret in its error surface.
        let store = InMemoryTokenSeam()
        try await store.saveToken(StoredToken(rawValue: "t"), for: GatewayID(rawValue: "g"))
        let loaded = try await store.loadToken(for: GatewayID(rawValue: "g"))
        XCTAssertEqual(loaded, StoredToken(rawValue: "t"))
    }

    func testCacheStoringIsSendableTypedSeam() {
        // The cache seam carries no token/credential parameter (structural:
        // verified by the FleetPersistence model + API tests too).
        let _: any CacheStoring = InMemoryCacheSeam()
    }
}

/// Minimal in-memory `TokenStoring` for the domain test (the real double lives
/// in FleetSecurity; this keeps FleetCore tests dependency-free).
private final class InMemoryTokenSeam: TokenStoring, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    func saveToken(_ token: StoredToken, for gatewayID: GatewayID) async throws {
        lock.withLock { storage in
            storage[gatewayID.rawValue] = token.rawValue
        }
    }
    func loadToken(for gatewayID: GatewayID) async throws -> StoredToken? {
        lock.withLock { storage in
            storage[gatewayID.rawValue].map(StoredToken.init(rawValue:))
        }
    }
    func deleteToken(for gatewayID: GatewayID) async throws {
        _ = lock.withLock { storage in
            storage.removeValue(forKey: gatewayID.rawValue)
        }
    }
}

/// Minimal in-memory `CacheStoring` for the domain test (proves the seam is
/// constructible with non-secret values only).
private final class InMemoryCacheSeam: CacheStoring, @unchecked Sendable {
    func saveHistory(_ history: SessionHistory, for gatewayID: GatewayID) async throws {}
    func loadHistory(sessionID: String, for gatewayID: GatewayID) async throws -> SessionHistory? { nil }
    func deleteHistory(sessionID: String, for gatewayID: GatewayID) async throws {}
    func saveWatermark(_ watermark: SessionEventWatermark, for gatewayID: GatewayID) async throws {}
    func loadWatermarks() async throws -> [SessionEventWatermark] { [] }
    func clearWatermarks() async throws {}
    func saveReplayEpoch(_ epoch: String?, for gatewayID: GatewayID) async throws {}
    func loadReplayEpoch(for gatewayID: GatewayID) async throws -> String? { nil }
    func resetForReplayEpochChange(gatewayID: GatewayID) async throws {}
}
