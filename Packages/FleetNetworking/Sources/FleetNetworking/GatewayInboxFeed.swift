import Foundation
import FleetCore

/// Concrete `InboxGatewayFeed` over ONE gateway transport.
///
/// Every inbound inbox event (server requests, the legacy `approval.request`
/// event, and `request.cancel`) arrives on the transport's conversation event
/// channel, which is ordered and covers all sessions. This feed maps that
/// channel onto `InboxFeedEvent` and nothing else: it does not filter by the
/// open conversation, and it never sends a request on its own. Answers go
/// through the same `GatewayApprovalClient` / `GatewayServerPromptClient`
/// that the conversation uses, over the SAME transport, because a server
/// request can only be answered on the transport that received it.
public struct GatewayInboxFeed: InboxGatewayFeed {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    public var approvals: any ApprovalsProviding {
        GatewayApprovalClient(gatewayID: gatewayID, transport: transport)
    }

    public var prompts: any ServerPromptResponding {
        GatewayServerPromptClient(gatewayID: gatewayID, transport: transport)
    }

    public func start() async throws {
        if case .connected = transport.state { return }
        try await transport.connect()
    }

    public func events() -> AsyncStream<InboxFeedEvent> {
        let source = transport.subscribeToConversationEvents()
        let (stream, continuation) = AsyncStream<InboxFeedEvent>.makeStream(bufferingPolicy: .unbounded)
        let pump = Task {
            for await event in source {
                if Task.isCancelled { break }
                if let mapped = InboxFeedEvent(conversationEvent: event) {
                    continuation.yield(mapped)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel() }
        return stream
    }

    public func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] {
        try await approvals.pendingApprovals(sessionID: sessionID)
    }
}
