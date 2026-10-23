import XCTest
import Foundation
@testable import FleetCore

/// The failure-kind vocabulary behind the session-lifecycle os.Logger events.
final class SessionLifecycleLogTests: XCTestCase {
    func testConnectivityErrorsMapToClosedKinds() {
        XCTAssertEqual(SessionLifecycleLog.failureKind(for: GatewayConnectivityError.timeout), .timeout)
        XCTAssertEqual(SessionLifecycleLog.failureKind(for: GatewayConnectivityError.authenticationRequired), .authRequired)
        XCTAssertEqual(SessionLifecycleLog.failureKind(for: GatewayConnectivityError.unreachable), .unreachable)
        XCTAssertEqual(SessionLifecycleLog.failureKind(for: GatewayConnectivityError.unsupported("x")), .other)
    }

    func testConversationErrorsMapToClosedKinds() {
        XCTAssertEqual(SessionLifecycleLog.failureKind(for: ConversationError.notConnected), .notConnected)
        XCTAssertEqual(SessionLifecycleLog.failureKind(for: ConversationError.sessionNotFound("s")), .sessionNotFound)
        XCTAssertEqual(SessionLifecycleLog.failureKind(for: ConversationError.sessionTooLongToReload(messageCount: 9000)), .sessionTooLong)
        XCTAssertEqual(SessionLifecycleLog.failureKind(for: ConversationError.rpcFailed("boom")), .rpc)
        XCTAssertEqual(SessionLifecycleLog.failureKind(for: ConversationError.malformedPayload("p")), .malformed)
    }

    func testURLTimeoutMapsToTimeoutAndUnknownErrorsToOther() {
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(SessionLifecycleLog.failureKind(for: timedOut), .timeout)
        struct Opaque: Error {}
        XCTAssertEqual(SessionLifecycleLog.failureKind(for: Opaque()), .other)
    }

    /// Raw values are the log vocabulary: they must stay stable, snake_case,
    /// and free of anything that could carry content.
    func testRawValuesAreStableClosedVocabulary() {
        for kind in SessionLifecycleLog.FailureKind.allCases {
            XCTAssertTrue(kind.rawValue.allSatisfy { $0.isLowercase || $0 == "_" }, kind.rawValue)
        }
        XCTAssertEqual(SessionLifecycleLog.FailureKind.authRequired.rawValue, "auth_required")
        XCTAssertEqual(SessionLifecycleLog.FailureKind.sessionTooLong.rawValue, "session_too_long")
    }

    func testMillisecondsIsNonNegative() {
        let now = ContinuousClock.now
        XCTAssertGreaterThanOrEqual(SessionLifecycleLog.milliseconds(since: now), 0)
        // A start in the future must clamp rather than go negative.
        let future = now.advanced(by: .seconds(5))
        XCTAssertEqual(SessionLifecycleLog.milliseconds(since: future), 0)
    }
}
