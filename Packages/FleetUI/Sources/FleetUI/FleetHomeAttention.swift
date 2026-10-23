import Foundation
import FleetCore

/// Pure rules for the inbox items Fleet Home counts and lists under
/// "Needs you". The inbox is the app-level source of pending decisions; Live
/// Ops approval rows already on Home are the same decisions seen through the
/// Live Ops poll, so an inbox item is dropped when its identity matches one of
/// those rows. No SwiftUI and no store access.
public enum FleetHomeAttention {

    /// Identity of the inbox item a Live Ops approval row stands for. Inbox
    /// approvals are keyed gateway # session # request, and Live Ops carries
    /// the same session and request ids on its pending approval.
    public static func inboxID(for item: LiveOpsAttentionItem) -> InboxItemID? {
        guard let approval = item.pendingApproval else { return nil }
        return InboxItemID(
            gatewayID: item.operation.id.gatewayID,
            sessionID: approval.sessionID,
            requestID: approval.requestID)
    }

    /// Pending inbox items Home lists, newest first, excluding any item that a
    /// Live Ops approval row already shows.
    public static func pendingInboxItems(
        inbox items: [InboxItem],
        liveOpsAttention: [LiveOpsAttentionItem]
    ) -> [InboxItem] {
        let shownByLiveOps = Set(liveOpsAttention.compactMap(inboxID(for:)))
        return FleetInboxPresentation.sections(items).pending.filter { !shownByLiveOps.contains($0.id) }
    }

    /// The "Needs you" count: observed Live Ops items, deduplicated inbox
    /// items, and the existing attention items. Each source is counted once.
    public static func needsYouCount(
        attentionCount: Int,
        liveOpsCount: Int,
        inboxPendingCount: Int
    ) -> Int {
        attentionCount + liveOpsCount + inboxPendingCount
    }

    /// Title and secondary line for a Home row that previews an inbox item.
    public static func rowTitle(_ item: InboxItem) -> String {
        FleetInboxPresentation.kindTitle(item.kind)
    }

    public static func rowDetail(_ item: InboxItem) -> String {
        "\(FleetInboxPresentation.actionSummary(item)) · \(FleetInboxPresentation.agentLine(item))"
    }
}
