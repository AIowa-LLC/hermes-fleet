import Foundation

/// The result of `session.interrupt`.
///
/// Wire shape (verified in `tui_gateway/methods_session.py:3329`): the handler
/// returns `{"status": "interrupted"}` (plus `{"turn_isolation": true}` on the
/// compute-host path). A successful interrupt stops the running turn; further
/// streaming events for that turn are not guaranteed.
public struct InterruptResult: Hashable, Sendable {
    /// The gateway-reported interrupt status (`"interrupted"`).
    public let status: String
    /// True on the compute-host path (`turn_isolation`), nil otherwise.
    public let turnIsolation: Bool?

    public init(status: String, turnIsolation: Bool? = nil) {
        self.status = status
        self.turnIsolation = turnIsolation
    }

    /// Whether the interrupt was acknowledged as interrupting a turn.
    public var isInterrupted: Bool { status == "interrupted" }
}
