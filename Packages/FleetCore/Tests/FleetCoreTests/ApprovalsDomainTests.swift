import XCTest
@testable import FleetCore

/// R9-T1 approval domain: `ApprovalRequest` / `ApprovalChoice` /
/// `ApprovalsProviding` (the seam FleetUI sees — never FleetNetworking), the
/// new `ConversationEvent.approvalRequested` case, the extended
/// `.sessionInfo` approval-mode fields, and the client-side command-preview
/// redaction pass.
final class ApprovalsDomainTests: XCTestCase {

    // MARK: ApprovalRequest

    func testApprovalRequestCarriesWireFields() {
        let request = ApprovalRequest(
            requestID: "abc123",
            sessionID: "sess-1",
            command: "echo 'fixture operation'",
            detail: "Run a fixture operation",
            choices: ["once", "session", "always", "deny"]
        )
        XCTAssertEqual(request.requestID, "abc123")
        XCTAssertEqual(request.sessionID, "sess-1")
        XCTAssertEqual(request.command, "echo 'fixture operation'")
        XCTAssertEqual(request.detail, "Run a fixture operation")
        XCTAssertEqual(request.choices, ["once", "session", "always", "deny"])
        // Identifiable rides the request id (stable, gateway-minted).
        XCTAssertEqual(request.id, "abc123")
    }

    func testChoiceVocabularyMatchesGateway() {
        // tools/approval.py _ApprovalEntry.result: "once"|"session"|"always"|"deny"
        XCTAssertEqual(ApprovalChoice.once.rawValue, "once")
        XCTAssertEqual(ApprovalChoice.session.rawValue, "session")
        XCTAssertEqual(ApprovalChoice.always.rawValue, "always")
        XCTAssertEqual(ApprovalChoice.deny.rawValue, "deny")
    }

    // MARK: ConversationEvent.approvalRequested

    func testApprovalRequestedEventExposesSessionAndSeq() {
        let event = ConversationEvent.approvalRequested(
            sessionID: "sess-1",
            requestID: "req-9",
            command: "printf 'fixture operation'",
            detail: nil,
            choices: ["once", "deny"],
            seq: 41
        )
        XCTAssertEqual(event.sessionID, "sess-1")
        XCTAssertEqual(event.seq, 41)
        if case .approvalRequested(let sid, let rid, let cmd, let detail, let choices, let seq) = event {
            XCTAssertEqual(sid, "sess-1")
            XCTAssertEqual(rid, "req-9")
            XCTAssertEqual(cmd, "printf 'fixture operation'")
            XCTAssertNil(detail)
            XCTAssertEqual(choices, ["once", "deny"])
            XCTAssertEqual(seq, 41)
        } else {
            XCTFail("expected approvalRequested")
        }
        // Not a turn-terminal frame — the turn keeps streaming while blocked.
        XCTAssertFalse(event.isTurnTerminal)
    }

    // MARK: sessionInfo approval-mode fields

    func testSessionInfoCarriesYoloAndApprovalMode() {
        let event = ConversationEvent.sessionInfo(
            sessionID: "sess-1",
            model: "m",
            provider: "p",
            title: nil,
            cwd: nil,
            profileName: nil,
            yolo: true,
            approvalMode: "manual",
            seq: 3
        )
        if case .sessionInfo(_, _, _, _, _, _, let yolo, let mode, _) = event {
            XCTAssertEqual(yolo, true)
            XCTAssertEqual(mode, "manual")
        } else {
            XCTFail("expected sessionInfo")
        }
        XCTAssertEqual(event.sessionID, "sess-1")
        XCTAssertEqual(event.seq, 3)
    }

    // MARK: Redaction.commandPreview (client-side second pass)

    func testCommandPreviewMasksTokenShapedSubstrings() {
        // Assemble the deterministic bearer fixture at runtime so the
        // repository scan cannot mistake it for a credential.
        let fixtureBearer = ["fixture", "bearer", "abc123"].joined(separator: "-")
        let masked = Redaction.commandPreview("curl -H 'Authorization: Bearer \(fixtureBearer)' https://api.example.invalid")
        XCTAssertTrue(masked.contains("[REDACTED]"), "bearer token must be masked: \(masked)")
        XCTAssertFalse(masked.contains(fixtureBearer))
        // Structure survives (this is a preview, not a full redact).
        XCTAssertTrue(masked.contains("curl -H"))
        XCTAssertTrue(masked.contains("https://api.example.invalid"))
    }

    func testCommandPreviewLeavesPlainCommandsAlone() {
        XCTAssertEqual(
            Redaction.commandPreview("printf 'fixture operation' && echo done"),
            "printf 'fixture operation' && echo done"
        )
        XCTAssertEqual(Redaction.commandPreview(""), "")
    }

    // MARK: ApprovalsProviding default (fail-closed)

    func testUnsupportedApprovalsRespondFailsClosed() async {
        let seam = UnsupportedApprovals()
        do {
            _ = try await seam.respond(
                sessionID: "s", requestID: "r", choice: .deny, all: false
            )
            XCTFail("respond must throw when the gateway has no approvals support")
        } catch {
            // expected — fail closed, never a silent no-op success
        }
        do {
            _ = try await seam.setSessionYolo(true, sessionID: "s")
            XCTFail("setSessionYolo must throw when unsupported")
        } catch {
            // expected
        }
        do {
            _ = try await seam.pendingApprovals(sessionID: "s")
            XCTFail("pendingApprovals must throw when unsupported")
        } catch {
            // expected
        }
    }
}
