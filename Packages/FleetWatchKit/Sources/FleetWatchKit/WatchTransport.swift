import Foundation

public enum WatchTransportError: Error, Equatable {
    /// Verified before sending: the phone link is not reachable, nothing left the Watch.
    case notReachable
    /// The request may have left the Watch but no valid reply arrived.
    case noReply
}

/// The Watch's only way to reach Fleet. There is no other network path and no
/// credential on this device.
@MainActor
public protocol WatchTransport: AnyObject {
    var linkState: WatchLinkState { get }
    var onSnapshot: ((WatchSnapshot) -> Void)? { get set }
    var onLinkChange: ((WatchLinkState) -> Void)? { get set }
    func activate()
    func send(_ request: WatchRequest) async throws -> WatchReply
    var isFixture: Bool { get }
}

