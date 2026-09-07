import Foundation

/// A per-gateway conversation session: connectivity + conversation + replay +
/// history over ONE transport (mirrors the M8 `GatewayRosterSession` pattern).
///
/// U3 composes the M3 connectivity seam (`GatewayConnectivityProviding`), the
/// M5 conversation seam (`ConversationProviding`), the M6 replay seam
/// (`ReplayProviding`) and the M4 read seam (`SessionHistoryProviding`) into
/// the unit the Conversation screen drives. Combining them means one object per
/// gateway owns the socket AND the create/resume/submit/interrupt calls AND the
/// streamed event channel AND the replay/watermark surface on that same socket
/// — so a reconnect re-hydrates exactly the events this session missed, and the
/// 4401 re-auth UX has a single explicit `reauthenticate()` entry point
/// (M11: NEVER a silent retry).
///
/// `GatewayConversationSession` (FleetNetworking) is the concrete; FleetUI
/// depends on this protocol — never on the transport module (M0 guard).
public protocol ConversationSessionProviding: GatewayConnectivityProviding {
    /// The conversation streaming seam (M5): session.create/resume,
    /// prompt.submit, session.interrupt + the streamed event channel.
    var conversation: any ConversationProviding { get }
    /// The reconnect/replay seam (M6): seq watermarks + replayAfterReconnect.
    var replay: any ReplayProviding { get }
    /// The read-only session history seam (M4): authoritative transcript
    /// refetch after a truncated replay / epoch change.
    var history: any SessionHistoryProviding { get }
    /// Explicit re-authentication after a 4401 close. Mints a FRESH ticket /
    /// reloads the loopback token — never a silent retry with the same
    /// credential (spec §8.6, M11). The UI decides WHEN to call this.
    func reauthenticate() async throws
}
