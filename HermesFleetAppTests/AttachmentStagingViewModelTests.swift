import XCTest
import FleetCore
import FleetPersistence
import FleetUI

/// R10-T1 hosted tests — the `ConversationViewModel` attachment tray over a
/// scripted `AttachmentStagingProviding` seam: pick → stage (wire attach) →
/// chip renders → send composes the `@file:` refs onto the prompt → tray
/// clears; pre-upload guards fire before any RPC; wire failures surface in
/// `attachmentError` (never silent); the fail-closed default throws honestly.
@MainActor
final class AttachmentStagingViewModelTests: XCTestCase {

    // MARK: - Scripted attachment seam

    private final class ScriptedAttachments: AttachmentStagingProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(method: String, sessionID: String, name: String, dataURL: String)] = []
        var calls: [(method: String, sessionID: String, name: String, dataURL: String)] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        /// When set, every attach throws this (after recording the call).
        var failure: AttachmentStagingError?

        private func record(_ method: String, _ sessionID: String, _ name: String, _ dataURL: String) -> AttachmentStagingError? {
            lock.lock(); defer { lock.unlock() }
            _calls.append((method, sessionID, name, dataURL))
            return failure
        }

        func attachFile(sessionID: String, name: String, dataURL: String) async throws -> StagedFileAttachment {
            if let failure = record("file.attach", sessionID, name, dataURL) { throw failure }
            let display = (name as NSString).lastPathComponent
            return StagedFileAttachment(
                name: display,
                path: "/srv/hermes/attachments/\(display)",
                refPath: "attachments/\(display)",
                refText: "@file:attachments/\(display)",
                uploaded: true)
        }

        func attachImageBytes(sessionID: String, filename: String, dataURL: String) async throws -> StagedImageAttachment {
            if let failure = record("image.attach_bytes", sessionID, filename, dataURL) { throw failure }
            return StagedImageAttachment(
                path: "/srv/hermes/images/upload_1.png",
                name: "upload_1.png",
                count: 1,
                byteCount: 2_048,
                width: 64,
                height: 64,
                tokenEstimate: 320)
        }

        func attachPDF(sessionID: String, filename: String, dataURL: String) async throws -> StagedPDFAttachment {
            if let failure = record("pdf.attach", sessionID, filename, dataURL) { throw failure }
            return StagedPDFAttachment(
                filename: filename,
                pagesAttached: 3,
                pages: [
                    StagedPDFPage(path: "/srv/hermes/images/pdf_p1_1.png", pageNumber: 1),
                    StagedPDFPage(path: "/srv/hermes/images/pdf_p2_2.png", pageNumber: 2),
                    StagedPDFPage(path: "/srv/hermes/images/pdf_p3_3.png", pageNumber: 3),
                ],
                count: 3)
        }

        func detachImage(sessionID: String, path: String) async throws -> DetachedImageState {
            DetachedImageState(detached: true, count: 0)
        }
    }

    // MARK: - Session double exposing the capability

    private final class AttachCapableSession: ConversationSessionProviding, AttachmentStagingCapable, @unchecked Sendable {
        let gatewayID = GatewayID(rawValue: "workstation")
        let attachmentsBox = ScriptedAttachments()
        var status: GatewayStatus { .online }
        var liveness: ConnectionLivenessSnapshot? { nil }
        func adoptedReady() async -> GatewayReadyAdoption? {
            GatewayReadyAdoption(replayEpoch: "epoch-1", heartbeatEnabled: false, changeEventsEnabled: true)
        }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: "MacBook") }
        func reauthenticate() async throws {}
        var conversation: any ConversationProviding { conversationDouble }
        let conversationDouble = ConversationDouble()
        var attachments: any AttachmentStagingProviding { attachmentsBox }

        fileprivate final class ConversationDouble: ConversationProviding, @unchecked Sendable {
            private let state = DispatchQueue(label: "attach.conversation.double")
            private var _submitted: [String] = []
            var submittedTexts: [String] {
                state.sync { _submitted }
            }
            func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
                ConversationSession(sessionID: "s-1", profileName: "default")
            }
            func resumeSession(sessionID: String, lastEventID: Int? = nil) async throws -> ConversationSession {
                ConversationSession(sessionID: sessionID, profileName: "default")
            }
            func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
                state.sync { _submitted.append(text) }
                return PromptSubmission(status: "streaming")
            }
            func interrupt(sessionID: String) async throws -> InterruptResult {
                InterruptResult(status: "interrupted")
            }
            var events: AsyncStream<ConversationEvent> {
                AsyncStream { _ in }
            }
            func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
        }

        var replay: any ReplayProviding { ReplayDouble() }
        private struct ReplayDouble: ReplayProviding {
            let gatewayID = GatewayID(rawValue: "workstation")
            func watermarks() async -> [SessionEventWatermark] { [] }
            func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }
        }
        var history: any SessionHistoryProviding { HistoryDouble() }
        private struct HistoryDouble: SessionHistoryProviding {
            func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
                SessionHistory(sessionID: sessionID, count: 0, messages: [])
            }
            func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
                SessionStatus.parse(output: "Session ID: \(sessionID)")
            }
        }
    }

    // MARK: - Fixture

    private func makeFixture() async throws -> (AttachCapableSession, ConversationViewModel) {
        let session = AttachCapableSession()
        let cache = try SwiftDataCacheStore.makeInMemory()
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default"))
        let viewModel = ConversationViewModel(
            session: session,
            cache: cache,
            route: route,
            sessionID: nil,
            statusInterval: .milliseconds(10))
        await viewModel.start()
        return (session, viewModel)
    }

    // MARK: - Tests

    func testStageFileAttachesOverWireAndAppendsChip() async throws {
        let (session, viewModel) = try await makeFixture()
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertTrue(viewModel.pendingAttachments.isEmpty)

        let payload = Data("# notes\nfixture".utf8)
        await viewModel.stageAttachment(
            name: "notes.md", mime: "text/markdown",
            byteCount: payload.count,
            loadBytes: { payload })

        // Wire ask: file.attach with a data:<mime>;base64, upload.
        XCTAssertEqual(session.attachmentsBox.calls.count, 1)
        let call = session.attachmentsBox.calls[0]
        XCTAssertEqual(call.method, "file.attach")
        XCTAssertEqual(call.sessionID, "s-1")
        XCTAssertEqual(call.name, "notes.md")
        XCTAssertTrue(call.dataURL.hasPrefix("data:text/markdown;base64,"))

        // Chip renders with the staged ref.
        XCTAssertEqual(viewModel.pendingAttachments.count, 1)
        XCTAssertEqual(viewModel.pendingAttachments[0].refText, "@file:attachments/notes.md")
        XCTAssertNil(viewModel.attachmentError)
    }

    func testSendComposesStagedRefsOntoPromptAndClearsTray() async throws {
        let (session, viewModel) = try await makeFixture()
        let payload = Data("csv,fixture".utf8)
        await viewModel.stageAttachment(
            name: "data.csv", mime: "text/csv",
            byteCount: payload.count,
            loadBytes: { payload })

        await viewModel.send("analyze this")

        let conversation = session.conversationDouble
        XCTAssertEqual(conversation.submittedTexts.count, 1)
        XCTAssertEqual(conversation.submittedTexts[0], "analyze this\n@file:attachments/data.csv")
        XCTAssertTrue(viewModel.pendingAttachments.isEmpty, "tray clears with the send")
        // The user row cites the composed text.
        XCTAssertTrue(viewModel.transcript.contains { $0.kind == .user && $0.text.contains("@file:attachments/data.csv") })
    }

    func testAttachOnlySendIsValid() async throws {
        let (session, viewModel) = try await makeFixture()
        let payload = Data("x".utf8)
        await viewModel.stageAttachment(
            name: "only.txt", mime: "text/plain",
            byteCount: payload.count,
            loadBytes: { payload })

        await viewModel.send("   ")

        let conversation = session.conversationDouble
        XCTAssertEqual(conversation.submittedTexts, ["@file:attachments/only.txt"])
    }

    func testRemovePendingAttachmentDropsChipWithoutWireCall() async throws {
        let (session, viewModel) = try await makeFixture()
        let payload = Data("x".utf8)
        await viewModel.stageAttachment(
            name: "gone.md", mime: "text/markdown",
            byteCount: payload.count,
            loadBytes: { payload })
        XCTAssertEqual(session.attachmentsBox.calls.count, 1)

        let chipID = try XCTUnwrap(viewModel.pendingAttachments.first?.id)
        viewModel.removePendingAttachment(chipID)
        XCTAssertTrue(viewModel.pendingAttachments.isEmpty)

        // No detach call fired (removal pre-send is cite-suppression only).
        XCTAssertEqual(session.attachmentsBox.calls.count, 1)
    }

    func testOversizedFileFailsBeforeUploadNeverSilent() async throws {
        let (session, viewModel) = try await makeFixture()
        let huge = Data(repeating: 0x41, count: AttachmentStagingRules.clientCapBytes + 1)

        await viewModel.stageAttachment(
            name: "huge.bin", mime: "application/octet-stream",
            byteCount: huge.count,
            loadBytes: { huge })

        // Pre-upload guard: no wire call was made.
        XCTAssertTrue(session.attachmentsBox.calls.isEmpty)
        XCTAssertNotNil(viewModel.attachmentError)
        XCTAssertTrue(viewModel.attachmentError?.contains("too large") == true,
                      "honest size error: \(viewModel.attachmentError ?? "")")
        XCTAssertTrue(viewModel.pendingAttachments.isEmpty)
    }

    func testWireFailureSurfacesComposerBannerAndKeepsDraft() async throws {
        let (session, viewModel) = try await makeFixture()
        session.attachmentsBox.failure = .rpcFailed("connection closed (fixture)")

        let payload = Data("y".utf8)
        await viewModel.stageAttachment(
            name: "draft.md", mime: "text/markdown",
            byteCount: payload.count,
            loadBytes: { payload })

        // The attach WAS attempted, failed, and surfaced — never silent.
        XCTAssertEqual(session.attachmentsBox.calls.count, 1)
        XCTAssertEqual(viewModel.attachmentError, "connection closed (fixture)")
        XCTAssertTrue(viewModel.pendingAttachments.isEmpty)

        // Banner dismisses.
        viewModel.clearAttachmentError()
        XCTAssertNil(viewModel.attachmentError)
    }

    func testImagePickRidesAttachBytesAndCitesMarker() async throws {
        let (session, viewModel) = try await makeFixture()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x02])
        await viewModel.stageAttachment(
            name: "photo_1.png", mime: nil,
            byteCount: png.count,
            loadBytes: { png })

        XCTAssertEqual(session.attachmentsBox.calls.count, 1)
        XCTAssertEqual(session.attachmentsBox.calls[0].method, "image.attach_bytes")
        XCTAssertTrue(session.attachmentsBox.calls[0].dataURL.hasPrefix("data:image/png;base64,"))
        XCTAssertEqual(viewModel.pendingAttachments[0].refText, "[User attached image: upload_1.png]")
    }

    func testPDFPickRidesPdfAttachAndCitesPages() async throws {
        let (session, viewModel) = try await makeFixture()
        let pdf = Data("%PDF-1.4 fixture".utf8)
        await viewModel.stageAttachment(
            name: "report.pdf", mime: nil,
            byteCount: pdf.count,
            loadBytes: { pdf })

        XCTAssertEqual(session.attachmentsBox.calls.count, 1)
        XCTAssertEqual(session.attachmentsBox.calls[0].method, "pdf.attach")
        XCTAssertTrue(session.attachmentsBox.calls[0].dataURL.hasPrefix("data:application/pdf;base64,"))
        XCTAssertEqual(viewModel.pendingAttachments[0].refText, "[User attached PDF: report.pdf (3 page(s))]")
    }

    func testSnifferMatchesGatewayImageSet() {
        // Mirrors _sniff_image_ext (server.py:14322-14340).
        XCTAssertEqual(AttachmentStagingRules.sniffedImageExtension(bytes: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), "png")
        XCTAssertEqual(AttachmentStagingRules.sniffedImageExtension(bytes: Data([0xFF, 0xD8, 0xFF, 0xE0])), "jpg")
        XCTAssertEqual(AttachmentStagingRules.sniffedImageExtension(bytes: Data("GIF89a".utf8)), "gif")
        XCTAssertEqual(AttachmentStagingRules.sniffedImageExtension(bytes: Data([0x42, 0x4D, 0x00, 0x00])), "bmp")
        var webp = Data("RIFF".utf8); webp.append(contentsOf: [0, 0, 0, 0]); webp.append(Data("WEBPVP8".utf8))
        XCTAssertEqual(AttachmentStagingRules.sniffedImageExtension(bytes: webp), "webp")
        // HEIC and arbitrary data: nil (fail honestly pre-upload).
        XCTAssertNil(AttachmentStagingRules.sniffedImageExtension(bytes: Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])))
        XCTAssertNil(AttachmentStagingRules.sniffedImageExtension(bytes: Data("hello".utf8)))
    }

    func testPromptAppendRules() {
        XCTAssertEqual(AttachmentStagingRules.promptAppending(refs: [], to: "hi"), "hi")
        XCTAssertEqual(AttachmentStagingRules.promptAppending(refs: ["@file:a.md"], to: "hi"), "hi\n@file:a.md")
        XCTAssertEqual(AttachmentStagingRules.promptAppending(refs: ["@file:a.md", "@file:b.md"], to: "  "), "@file:a.md @file:b.md")
        XCTAssertEqual(AttachmentStagingRules.promptAppending(refs: ["@file:a.md"], to: "  hi  "), "hi\n@file:a.md")
    }
}
