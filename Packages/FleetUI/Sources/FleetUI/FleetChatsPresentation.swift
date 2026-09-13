import Foundation
import FleetCore

/// Chat-list polish (dogfood finding 1) — how the Chats screen reports a
/// PARTIAL refresh failure.
///
/// A refresh can fail for some routes while other routes still hold usable
/// cached/retained sessions. Reporting the failure is mandatory (never
/// silent), but it must not push a list the user can actually use off the
/// screen: with usable conversations present the failure is a compact inline
/// line plus `Retry`; with nothing usable to show, the honest surface is the
/// stronger empty/error state.
///
/// Pure presentation policy — the view renders from this decision, so the
/// behavior is unit-testable without a UI host. Navigation, protocol, and
/// gateway semantics are untouched.
public enum RefreshFailureSurface: Equatable, Sendable {
    /// No retryable route failed — nothing to report.
    case none
    /// Failure with usable conversations: compact, inline, list stays primary.
    case inline
    /// Failure with no usable conversations: the stronger empty/error state.
    case prominent
}

public enum FleetChatsPresentation {

    /// Which failure surface the Chats list renders.
    ///
    /// - Parameters:
    ///   - failedRouteCount: retryable routes whose session read failed
    ///     (already scoped by `currentFailureRoutes`).
    ///   - hasUsableSessions: at least one cached/retained conversation exists
    ///     on a route this screen can still render — including a session
    ///     retained from a bot that dropped out of the live roster (FOS-5
    ///     outage retention).
    public static func refreshFailureSurface(
        failedRouteCount: Int,
        hasUsableSessions: Bool
    ) -> RefreshFailureSurface {
        guard failedRouteCount > 0 else { return .none }
        return hasUsableSessions ? .inline : .prominent
    }

    /// The failed routes the Chats screen REPORTS — the intersection of the
    /// routes whose read failed and the routes still in the current roster.
    ///
    /// `FleetChatsView.refresh()` re-reads the CURRENT roster only, so an error
    /// recorded for a route that has since left the roster can never be cleared
    /// by this screen's `Retry`; reporting it would pin the failure line on
    /// screen forever. Scoping to the roster makes the reported failures exactly
    /// the ones this screen can still retry — while every failure stays visible
    /// on the owner surface (Bot detail) that CAN retry it.
    public static func currentFailureRoutes(
        failedRoutes: Set<Route>,
        rosterRoutes: Set<Route>
    ) -> Set<Route> {
        failedRoutes.intersection(rosterRoutes)
    }

    /// Detail copy for the prominent, nothing-to-show failure surface.
    ///
    /// Truthful about scope: it may only claim that NO gateway returned
    /// conversations when every current route failed. When some routes failed
    /// and the rest simply had zero sessions it says so instead, so the user is
    /// never told their whole fleet is down when it is not.
    public static func prominentFailureDetail(
        failedRouteCount: Int,
        totalRouteCount: Int
    ) -> String {
        let allRoutesFailed = totalRouteCount > 0 && failedRouteCount >= totalRouteCount
        return allRoutesFailed
            ? "None of your gateways returned conversations, and none were previously loaded. Check the connection to your gateways, then retry."
            : "Some gateways could not be reached, and the rest returned no conversations. Check the connection to your gateways, then retry."
    }
}

/// Chat-list polish (dogfood finding 3) — layout facts for the Chats list.
public enum FleetChatsListLayout {

    /// Extra scroll room below the last card so it can come to rest clear of
    /// the iOS 26 floating tab bar. This is added ON TOP of the tab bar's own
    /// safe-area inset (the reported dogfood defect: the final card tucked
    /// under the floating bar). A design-token value, never a device magic
    /// number — pinned by `FleetChatsPresentationTests`.
    public static let bottomBreathingRoom: CGFloat = FleetTheme.spacingXl
}