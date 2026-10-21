import Foundation
import FleetCore

/// #188 — the dashboard REST paged-history client
/// (`GET /api/sessions/{id}/messages?order=latest&limit=N&offset=K`).
///
/// Modeled on `DashboardCronClient`: the same injected `httpCredential`
/// resolver (one credential path per gateway), the same `urlSession`, the same
/// strict path-segment encoding and `RoutingGuard` checks. Rows are RAW DB
/// rows, not the `session.history` projection, so they are decoded here:
/// `display_content` (preferred) → `content` (string, or text/image parts),
/// hidden rows dropped, tool names resolved from the assistant `tool_calls`
/// of the same page.
///
/// `order=latest` pages back from the newest row: `offset` skips the K newest
/// rows and the page comes back oldest→newest. `returned` counts raw rows
/// before any filtering; that count (not the decoded count) advances paging.
public struct DashboardSessionMessagesClient: SessionHistoryPaging, Sendable {
    public let gatewayID: GatewayID
    /// HTTP base of the dashboard server (`http(s)://host:port`).
    let baseURL: URL
    let httpCredential: @Sendable () async throws -> KanbanEventStreamClient.HTTPCredential
    let urlSession: URLSession

    /// Server-side page ceiling (`limit` is capped at 500 by the gateway).
    public static let maxLimit = 500
    /// Largest page body accepted. A page of rich tool output can exceed the
    /// 8 MB auth-REST cap, so pages use the same 16 MB ceiling as the
    /// WebSocket frame this path exists to work around.
    static let maxPageBytes = JSONRPCCodec.maxFrameBytes

    public init(
        gatewayID: GatewayID,
        baseURL: URL,
        httpCredential: @escaping @Sendable () async throws -> KanbanEventStreamClient.HTTPCredential = { .none },
        urlSession: URLSession = .shared
    ) {
        self.gatewayID = gatewayID
        self.baseURL = baseURL
        self.httpCredential = httpCredential
        self.urlSession = urlSession
    }

    // MARK: - URL building (pure, testable)

    /// `…/api/sessions/{id}/messages?order=latest&limit=L&offset=K&inline_images=false[&profile=P]`.
    /// `limit` is clamped to 1…500; a negative `offset` becomes 0. Nil when the
    /// session id or profile is not a safe routing key, or the base URL cannot
    /// be used — the caller maps that to `.malformed`, never a trap.
    public static func messagesURL(
        base: URL, sessionID: String, profile: String?, offset: Int, limit: Int
    ) -> URL? {
        guard RoutingGuard.isValidSessionKey(sessionID) else { return nil }
        if let profile, !profile.isEmpty, !RoutingGuard.isValidRouteComponent(profile) { return nil }
        var query: [URLQueryItem] = [
            URLQueryItem(name: "order", value: "latest"),
            URLQueryItem(name: "limit", value: String(clampedLimit(limit))),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
            URLQueryItem(name: "inline_images", value: "false"),
        ]
        if let profile, !profile.isEmpty {
            query.append(URLQueryItem(name: "profile", value: profile))
        }
        let segment = DashboardCronClient.encodedSegment(sessionID)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = GatewayEndpoint.path(joining: "/api/sessions/\(segment)/messages", onto: base)
        components?.queryItems = query
        return components?.url
    }

    /// The gateway's page window: 1…500.
    static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, 1), maxLimit)
    }

    // MARK: - SessionHistoryPaging

    public func fetchLatestPage(
        sessionID: String, profile: String?, offset: Int, limit: Int
    ) async throws -> SessionHistoryPage {
        guard RoutingGuard.isValidSessionKey(sessionID) else {
            throw SessionHistoryPagingError.sessionNotFound("session_id is not a safe session key")
        }
        let safeOffset = max(0, offset)
        let safeLimit = Self.clampedLimit(limit)
        guard let url = Self.messagesURL(
            base: baseURL, sessionID: sessionID, profile: profile, offset: safeOffset, limit: safeLimit)
        else {
            throw SessionHistoryPagingError.malformed("bad messages URL")
        }
        let data = try await perform(url: url)
        return try Self.decodePage(data, offset: safeOffset, limit: safeLimit)
    }

    // MARK: - Page decode (pure, testable)

    /// `{session_id, profile, messages: [row…], pagination: {limit, offset,
    /// order, returned}}` → one page. `returned` is taken from `pagination`
    /// when present (raw count); otherwise the raw row count is used.
    static func decodePage(_ data: Data, offset: Int, limit: Int) throws -> SessionHistoryPage {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue,
              let rows = object["messages"]?.arrayValue else {
            throw SessionHistoryPagingError.malformed("page decode failed")
        }
        let returned = object["pagination"]?.objectValue?["returned"]?.intValue ?? rows.count
        return SessionHistoryPage(
            messages: decodeRows(rows),
            offset: offset,
            limit: limit,
            returned: max(0, returned))
    }

    /// Raw rows (chronological) → renderable messages. Hidden rows and rows
    /// with no renderable content are dropped. Tool rows resolve their name
    /// from the assistant `tool_calls` of the SAME page; a call from an older
    /// page falls back to `"tool"`.
    static func decodeRows(_ rows: [JSONValue]) -> [SessionMessage] {
        var toolNames: [String: String] = [:]
        for row in rows {
            guard let object = row.objectValue,
                  object["role"]?.stringValue == "assistant",
                  let calls = object["tool_calls"]?.arrayValue else { continue }
            for call in calls {
                guard let callObject = call.objectValue,
                      let callID = callObject["id"]?.stringValue,
                      let function = callObject["function"]?.objectValue,
                      let name = nonEmpty(function["name"]?.stringValue) else { continue }
                toolNames[callID] = name
            }
        }
        return rows.compactMap { row in
            guard let object = row.objectValue else { return nil }
            return decodeRow(object, toolNames: toolNames)
        }
    }

    static func decodeRow(_ object: [String: JSONValue], toolNames: [String: String]) -> SessionMessage? {
        // display_kind == hidden is a server-side hide; never render it.
        if object["display_kind"]?.stringValue == "hidden" { return nil }
        let role = SessionMessageRole(wire: object["role"]?.stringValue ?? "")
        // Durable row id: the integer `id`, carried as its decimal string.
        let rowID: String? = object["id"]?.intValue.map(String.init)
        let reasoning = GatewaySessionHistoryClient.firstReasoningText(in: object)
        let reactions = object["display_metadata"].flatMap {
            GatewaySessionHistoryClient.decodeReactions(fromMetadata: $0)
        }
        var text = displayText(object)
        var toolName: String?
        if role == .tool {
            // Tool rows render by name; the result body is not shown inline.
            text = ""
            toolName = nonEmpty(object["tool_name"]?.stringValue)
                ?? nonEmpty(object["tool_call_id"]?.stringValue).flatMap { toolNames[$0] }
                ?? "tool"
        }
        let message = SessionMessage(
            role: role,
            text: text,
            timestamp: object["timestamp"]?.numberValue,
            rowID: rowID,
            displayKind: object["display_kind"]?.stringValue,
            reasoning: reasoning,
            toolName: toolName,
            toolContext: nil,
            reactions: reactions)
        return message.hasContent ? message : nil
    }

    /// `display_content` when it is a non-empty string, else the `content`
    /// string, else the joined text parts (`[image]` for image parts).
    static func displayText(_ object: [String: JSONValue]) -> String {
        if let display = nonEmpty(object["display_content"]?.stringValue) {
            return display
        }
        switch object["content"] {
        case .string(let text)?:
            return text
        case .array(let parts)?:
            return parts.compactMap { part -> String? in
                guard let partObject = part.objectValue else { return nil }
                let type = partObject["type"]?.stringValue ?? ""
                if type == "text" || type == "input_text" || type == "output_text" {
                    return nonEmpty(partObject["text"]?.stringValue)
                }
                if type.contains("image") { return "[image]" }
                return nil
            }.joined(separator: "\n")
        default:
            return ""
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Request plumbing

    private func perform(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AuthREST.bounded(&request)
        do {
            switch try await httpCredential() {
            case .none:
                break
            case .sessionTokenHeader(let token):
                request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
            case .cookie(let cookie):
                request.setValue(cookie.headerValue, forHTTPHeaderField: "Cookie")
            case .bearer(let token):
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        } catch {
            if Redaction.isCancellation(error) { throw CancellationError() }
            throw SessionHistoryPagingError.transport(Redaction.userFacingErrorDescription(error))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.boundedData(for: request, limit: Self.maxPageBytes)
        } catch {
            if Redaction.isCancellation(error) { throw CancellationError() }
            throw SessionHistoryPagingError.transport(Redaction.userFacingErrorDescription(error))
        }
        guard data.count <= Self.maxPageBytes else {
            throw SessionHistoryPagingError.malformed("page response too large")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SessionHistoryPagingError.malformed("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapStatus(http.statusCode, body: data)
        }
        return data
    }

    /// Status → typed paging error. A 404 whose FastAPI detail is the generic
    /// `Not Found` means the ROUTE is missing (older gateway) → `.unsupported`;
    /// any other 404 names an unknown session.
    static func mapStatus(_ status: Int, body: Data) -> SessionHistoryPagingError {
        let detail = DashboardCronClient.errorDetail(body)
        switch status {
        case 401, 403:
            return .unauthorized
        case 404:
            if detail == nil || detail == "Not Found" {
                return .unsupported("this gateway has no paged history route")
            }
            return .sessionNotFound("the gateway does not know this session")
        case 405, 501:
            return .unsupported("this gateway does not support paged history")
        case 400, 422:
            return .malformed("the gateway rejected the page request")
        default:
            return .transport("the gateway answered HTTP \(status)")
        }
    }
}
