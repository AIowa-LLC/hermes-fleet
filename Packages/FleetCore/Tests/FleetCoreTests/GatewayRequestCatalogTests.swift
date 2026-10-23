import XCTest
@testable import FleetCore

/// Timeout copy for gateway RPCs: each message names the operation that timed
/// out, reads offer Retry, and writes warn that the change may have applied.
final class GatewayRequestCatalogTests: XCTestCase {

    func testReadTimeoutNamesOperationAndOffersRetry() {
        XCTAssertEqual(
            GatewayRequestCatalog.timeoutMessage(forMethod: "session.history"),
            "Loading messages timed out. Check your connection and tap Retry."
        )
        XCTAssertEqual(
            GatewayRequestCatalog.timeoutMessage(forMethod: "profiles.list"),
            "Loading profiles timed out. Check your connection and tap Retry."
        )
    }

    func testWriteTimeoutDoesNotInviteBlindRetry() {
        let message = GatewayRequestCatalog.timeoutMessage(forMethod: "prompt.submit")
        XCTAssertEqual(
            message,
            "Sending your message timed out before the gateway confirmed it. Check the conversation or settings before trying again."
        )
        XCTAssertFalse(message.contains("Retry"))
    }

    func testUnknownMethodFallsBackToGenericCopy() {
        XCTAssertNil(GatewayRequestCatalog.operationLabel(forMethod: "made.up.method"))
        XCTAssertEqual(
            GatewayRequestCatalog.timeoutMessage(forMethod: "made.up.method"),
            "The gateway didn't respond in time. Check your connection and tap Retry."
        )
    }

    func testEveryRetryableReadHasAHumanLabelOrFallsBack() {
        // Retryable reads should read well in copy; a missing label still
        // produces a sentence (no raw method name leaks to the user).
        for method in GatewayRequestCatalog.idempotentReads {
            let message = GatewayRequestCatalog.timeoutMessage(forMethod: method)
            XCTAssertTrue(message.hasSuffix("tap Retry."), method)
            XCTAssertFalse(message.contains(method), method)
        }
    }

    func testConversationTimeoutSurfacesCopyWithoutRPCPrefix() {
        let error = ConversationError.requestTimedOut(method: "session.history")
        XCTAssertEqual(
            Redaction.userFacingErrorDescription(error),
            "Loading messages timed out. Check your connection and tap Retry."
        )
    }

    func testSessionHistoryTimeoutSurfacesCopyWithoutRPCPrefix() {
        let error = SessionHistoryError.requestTimedOut(method: "session.status")
        XCTAssertEqual(
            Redaction.userFacingErrorDescription(error),
            "Checking session status timed out. Check your connection and tap Retry."
        )
    }
}
