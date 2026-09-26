import XCTest
import FleetCore
@testable import FleetNetworking

/// Build 41 — REST mutation wire tests over the URLProtocol mock (same
/// pattern as the snapshot tests): request shape (method/path/query/body),
/// error-detail mapping, and response decoding.
final class KanbanTaskMutationsTests: XCTestCase {

    // MARK: Test infrastructure

    final class MutationURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        /// Bodies captured at protocol time (URLSession may drain
        /// httpBodyStream before the handler sees the request).
        nonisolated(unsafe) static var lastBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}

        private static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 16 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> KanbanEventStreamClient {
        MutationURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MutationURLProtocol.self]
        return KanbanEventStreamClient(
            gatewayID: GatewayID(rawValue: "gw"),
            baseURL: URL(string: "https://gateway.example.invalid:9119")!,
            authenticator: StaticAuthenticator(authentication: .none),
            httpCredential: { .none },
            urlSession: URLSession(configuration: config))
    }

    private func body<T: Decodable>(_ type: T.Type, from request: URLRequest) -> T? {
        guard let data = MutationURLProtocol.lastBody else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: Create

    func testCreateTaskSendsCorrectShapeAndDecodesCard() async throws {
        var seenRequest: URLRequest?
        let client = makeClient { request in
            seenRequest = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload = #"{"task":{"id":"t_new1","title":"New work","status":"todo","assignee":"apple-dev","priority":2,"created_at":1788366000.0,"latest_summary":null},"warning":null}"#
            return (response, Data(payload.utf8))
        }
        let card = try await client.createTask(
            KanbanTaskDraft(title: "New work", assignee: "apple-dev", priority: 2, triage: false))
        XCTAssertEqual(card.id, "t_new1")
        XCTAssertEqual(card.title, "New work")
        XCTAssertEqual(card.status, "todo")

        let request = try XCTUnwrap(seenRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.path.hasSuffix("/api/plugins/kanban/tasks") ?? false)
        struct Body: Decodable {
            let title: String
            let assignee: String?
            let priority: Int
            let triage: Bool
        }
        let decoded = try XCTUnwrap(body(Body.self, from: request))
        XCTAssertEqual(decoded.title, "New work")
        XCTAssertEqual(decoded.assignee, "apple-dev")
        XCTAssertEqual(decoded.priority, 2)
        XCTAssertEqual(decoded.triage, false)
    }

    func testCreateTaskPinsBoardQueryExactlyOnce() async throws {
        var seenQuery: String?
        let client = makeClient { request in
            seenQuery = request.url?.query
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"task":{"id":"t_x","title":"x","status":"todo"}}"#.utf8))
        }
        await client.pinBoard("r10")
        _ = try await client.createTask(KanbanTaskDraft(title: "x"))
        let query = try XCTUnwrap(seenQuery)
        XCTAssertEqual(
            query.split(separator: "&").filter { $0 == "board=r10" }.count, 1,
            "the pinned board must ride the query exactly once (got: \(query))")
    }

    func testCreateTaskSurfaces400DetailAsRejection() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"detail":"title is required"}"#.utf8))
        }
        do {
            _ = try await client.createTask(KanbanTaskDraft(title: ""))
            XCTFail("expected rejection")
        } catch let error as KanbanMutationError {
            XCTAssertEqual(error, .rejected("title is required"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: Update (PATCH)

    func testUpdateTaskSendsPartialPatchAndDecodesCard() async throws {
        var seenRequest: URLRequest?
        let client = makeClient { request in
            seenRequest = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload = #"{"task":{"id":"t_1","title":"Renamed","status":"done","priority":3}}"#
            return (response, Data(payload.utf8))
        }
        let card = try await client.updateTask(
            id: "t_1",
            patch: KanbanTaskPatch(status: "done", summary: "Shipped"))
        XCTAssertEqual(card.status, "done")

        let request = try XCTUnwrap(seenRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertTrue(request.url?.path.hasSuffix("/api/plugins/kanban/tasks/t_1") ?? false)
        // A nil field is OMITTED from the JSON (partial-edit semantics).
        let json = try XCTUnwrap(
            MutationURLProtocol.lastBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertNotNil(json["status"])
        XCTAssertNotNil(json["summary"])
        XCTAssertNil(json["title"], "an untouched field must not be sent")
        XCTAssertNil(json["assignee"], "an untouched field must not be sent")
    }

    func testUpdateTaskSurfaces409WithBlockingParents() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            let payload = #"{"detail":"Cannot move to 'ready': blocked by parent(s) not done — 'Upstream' (t_9, status=todo)"}"#
            return (response, Data(payload.utf8))
        }
        do {
            _ = try await client.updateTask(id: "t_1", patch: KanbanTaskPatch(status: "ready"))
            XCTFail("expected rejection")
        } catch let error as KanbanMutationError {
            guard case .rejected(let detail) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(detail.contains("blocked by parent"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testUpdateTaskEmptyAssigneeRidesWireAsEmptyString() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"task":{"id":"t_1","title":"x","status":"todo"}}"#.utf8))
        }
        _ = try await client.updateTask(id: "t_1", patch: KanbanTaskPatch(assignee: ""))
        let seenBody = MutationURLProtocol.lastBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        XCTAssertEqual(seenBody?["assignee"] as? String, "", "empty string = explicit unassign")
    }

    // MARK: Detail

    func testFetchTaskDetailDecodesBundle() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload = """
            {"task":{"id":"t_1","title":"Full","body":"Body text","status":"running","priority":2,
              "assignee":"apple-dev","workspace_kind":"worktree","skills":["codex"],
              "created_at":1788366000,"goal_mode":true},
             "comments":[{"id":1,"task_id":"t_1","author":"dashboard","body":"hi","created_at":1788366100}],
             "events":[{"id":9,"task_id":"t_1","run_id":null,"kind":"status","created_at":1788366200}],
             "links":{"parents":["t_0"],"children":["t_2"]},
             "child_results":[{"id":"t_2","title":"Child","status":"done","latest_summary":"ok","result":null}],
             "runs":[{"id":4,"task_id":"t_1","profile":"apple-dev","status":"running",
               "started_at":1788366000,"ended_at":null,"outcome":null,"summary":"working","error":null,"worker_pid":123}]}
            """
            return (response, Data(payload.utf8))
        }
        let detail = try await client.fetchTaskDetail(id: "t_1")
        XCTAssertEqual(detail.task.id, "t_1")
        XCTAssertEqual(detail.task.goalMode, true)
        XCTAssertEqual(detail.comments.first?.body, "hi")
        XCTAssertEqual(detail.links.parents, ["t_0"])
        XCTAssertEqual(detail.childResults.first?.id, "t_2")
        XCTAssertEqual(detail.runs.first?.profile, "apple-dev")
        XCTAssertEqual(detail.runs.first?.workerPID, 123)
    }

    // MARK: Comments / links / bulk

    func testAddCommentSendsBodyAndAuthor() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"ok":true}"#.utf8))
        }
        try await client.addComment(taskID: "t_1", body: "note", author: nil)
        let seenBody = MutationURLProtocol.lastBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        XCTAssertEqual(seenBody?["body"] as? String, "note")
        XCTAssertEqual(seenBody?["author"] as? String, "dashboard",
                       "nil author defaults to dashboard (server default)")
    }

    func testBulkUpdateDecodesPerIdOutcomes() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload = #"{"results":[{"id":"t_1","ok":true},{"id":"t_2","ok":false,"error":"not found"}]}"#
            return (response, Data(payload.utf8))
        }
        let outcomes = try await client.bulkUpdate(
            KanbanBulkPatch(ids: ["t_1", "t_2"], status: "done"))
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes[0].ok)
        XCTAssertEqual(outcomes[1].error, "not found")
    }

    // MARK: Recovery actions

    func testReclaimRejectsNonRunningWithServerCopy() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"detail":"cannot reclaim t_1: not in a claimable state (not running, or unknown id)"}"#.utf8))
        }
        do {
            try await client.reclaimTask(id: "t_1", reason: nil)
            XCTFail("expected rejection")
        } catch let error as KanbanMutationError {
            XCTAssertTrue(String(describing: error).contains("claimable"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSpecifyOutcomeDecodesOkFalseAsValue() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"ok":false,"task_id":"t_1","reason":"specifier unavailable","new_title":null}"#.utf8))
        }
        let outcome = try await client.specifyTask(id: "t_1", author: nil)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(
            outcome.taskID, "t_1",
            "task_id is the wire key — a wrong mapping silently decodes nil")
        XCTAssertEqual(outcome.reason, "specifier unavailable")
    }

    // MARK: Orchestration / dispatch / assignees

    func testOrchestrationSettingsDecode() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload = #"{"orchestrator_profile":"apple-dev","default_assignee":"","auto_decompose":true,"auto_promote_children":false,"resolved_orchestrator_profile":"apple-dev","resolved_default_assignee":"default","active_profile":"default"}"#
            return (response, Data(payload.utf8))
        }
        let settings = try await client.orchestrationSettings()
        XCTAssertEqual(settings.orchestratorProfile, "apple-dev")
        XCTAssertEqual(settings.autoDecompose, true)
        XCTAssertEqual(settings.autoPromoteChildren, false)
        XCTAssertEqual(settings.resolvedDefaultAssignee, "default")
    }

    func testDispatchNudgeDecodesTupleBuckets() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload = #"{"reclaimed":1,"promoted":2,"spawned":[["t_1","apple-dev","/tmp/w"]],"skipped_unassigned":[],"skipped_per_profile_capped":[["t_2","apple-qa",3]],"crashed":[],"auto_blocked":[],"timed_out":[],"stale":[],"respawn_guarded":[],"rate_limited":[],"skipped_locked":false,"memory_pressure":null}"#
            return (response, Data(payload.utf8))
        }
        let result = try await client.dispatchNudge(dryRun: false, max: 8)
        XCTAssertEqual(result.reclaimed, 1)
        XCTAssertEqual(result.spawned?.first?.taskID, "t_1")
        XCTAssertEqual(result.skippedPerProfileCapped?.first?.runningCount, 3)
    }

    func testAssigneesDecode() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"assignees":["apple-dev","default"]}"#.utf8))
        }
        let names = try await client.fetchAssignees()
        XCTAssertEqual(names, ["apple-dev", "default"])
    }

    // MARK: Snapshot with archived

    func testSnapshotIncludeArchivedAddsQuery() async throws {
        var seenQuery: String?
        let client = makeClient { request in
            seenQuery = request.url?.query
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload = #"{"columns":[{"name":"todo","tasks":[]},{"name":"archived","tasks":[{"id":"t_a","title":"Old","status":"archived"}]}],"latest_event_id":5,"now":1}"#
            return (response, Data(payload.utf8))
        }
        let snapshot = try await client.snapshot(includeArchived: true)
        XCTAssertEqual(snapshot.columns, ["todo", "archived"])
        XCTAssertEqual(snapshot.totalCards, 1)
        XCTAssertTrue(seenQuery?.contains("include_archived=true") ?? false)
    }

    /// Archived + pinned must not double the `board` parameter: `pluginRequest`
    /// owns it for every call (the local copy produced `board=X&…&board=X`).
    func testSnapshotIncludeArchivedWithPinnedBoardSendsOneBoardParam() async throws {
        var seenQuery: String?
        let client = makeClient { request in
            seenQuery = request.url?.query
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload = #"{"columns":[{"name":"todo","tasks":[]},{"name":"archived","tasks":[{"id":"t_a","title":"Old","status":"archived"}]}],"latest_event_id":5,"now":1}"#
            return (response, Data(payload.utf8))
        }
        await client.pinBoard("r10")
        let snapshot = try await client.snapshot(includeArchived: true)
        XCTAssertEqual(snapshot.columns, ["todo", "archived"])
        let query = try XCTUnwrap(seenQuery)
        XCTAssertEqual(
            query.split(separator: "&").filter { $0.hasPrefix("board=") }.count, 1,
            "the pinned board must ride the query exactly once (got: \(query))")
        XCTAssertTrue(query.contains("board=r10"))
        XCTAssertTrue(query.contains("include_archived=true"))
    }

    // MARK: Create warning (dispatcher presence)

    /// `POST /tasks` carries the server's optional `warning` (a ready+assigned
    /// create with no running dispatcher). `createTask` keeps its card-only
    /// contract; `createTaskWithWarning` surfaces the banner.
    func testCreateTaskWithWarningSurfacesServerBanner() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload = #"{"task":{"id":"t_new1","title":"Ready work","status":"ready","assignee":"apple-dev"},"warning":"No dispatcher is running for this gateway - the card will stay in ready until one starts."}"#
            return (response, Data(payload.utf8))
        }
        let creation = try await client.createTaskWithWarning(
            KanbanTaskDraft(title: "Ready work", assignee: "apple-dev"))
        XCTAssertEqual(creation.card.id, "t_new1")
        XCTAssertEqual(creation.card.status, "ready")
        XCTAssertEqual(
            creation.warning,
            "No dispatcher is running for this gateway - the card will stay in ready until one starts.")
    }

    func testCreateTaskWithoutWarningReportsNil() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload = #"{"task":{"id":"t_new2","title":"Plain","status":"todo"}}"#
            return (response, Data(payload.utf8))
        }
        let creation = try await client.createTaskWithWarning(KanbanTaskDraft(title: "Plain"))
        XCTAssertEqual(creation.card.id, "t_new2")
        XCTAssertNil(creation.warning)
    }
}
