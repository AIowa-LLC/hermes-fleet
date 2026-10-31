import XCTest
import SwiftUI
@testable import FleetUI

/// Issue #215 regression: opening a conversation overflowed the main-thread
/// stack on the Wi-Fi (Debug) build and crash-looped the app on relaunch.
///
/// The screen was one `some View` value: the composer, header, find bar,
/// toolbelt and pushed-conversation destinations were inlined into
/// `canvas(_:)` and from there into `ConversationView.body`. In an unoptimized
/// build every frame of that body evaluation keeps about a dozen copies of the
/// value, so its size sets the stack cost. Measured on the iOS Simulator with
/// a painted main-thread stack, before the fix:
///
/// - `MemoryLayout<ConversationView.Body>.size` = 26,088 bytes;
/// - ~1,021,000 bytes of main-thread stack already in use when the composer
///   resolved its 34-level generic type, ~1,104,000 peak — over a device's
///   1 MB main-thread stack, and identical for a short chat and a 25,000-row
///   one (the cost is the view's type, not the conversation's content).
///
/// The fix gives those sections nominal `View` types. These checks pin the
/// two properties that matter and are deterministic: the body value stays
/// small, and the extracted sections stay out of line.
final class ConversationStackBudgetTests: XCTestCase {

    /// After the fix the body is 9,032 bytes and opening a conversation peaks
    /// at ~423,000 bytes of main-thread stack (composer entry ~89,000). The
    /// budget leaves room for ordinary growth while failing long before the
    /// body could approach the pre-fix size again.
    private static let bodyValueBudget = 12_000

    func testConversationBodyValueStaysWithinStackBudget() {
        let size = MemoryLayout<ConversationView.Body>.size
        XCTAssertLessThanOrEqual(
            size, Self.bodyValueBudget,
            "ConversationView.body grew to \(size) bytes; Debug builds copy it into every body frame (#215). Move the new section into its own View type.")
    }

    func testComposerAndChromeAreNominalViewsNotInlined() {
        let bodyType = String(reflecting: ConversationView.Body.self)
        for nominal in ["ConversationComposer", "ConversationHeader", "ConversationFindBar",
                        "ConversationToolbelt", "ConversationDestination"] {
            XCTAssertTrue(bodyType.contains("FleetUI.\(nominal)"),
                          "\(nominal) must stay a nominal child of ConversationView (#215)")
        }
        // The composer's field and the find bar's field are the canonical
        // signs of those sections being inlined again.
        XCTAssertFalse(bodyType.contains("SwiftUI.TextField"),
                       "a TextField is inlined into ConversationView.body again (#215)")
    }

    func testComposerTypeDepthIsBounded() {
        // Pre-fix the composer resolved a 34-level type on top of ~1 MB of
        // stack. As its own view it resolves in a separate, shallow update;
        // keep its own type from regrowing (27 after the fix).
        XCTAssertLessThanOrEqual(Self.genericDepth(of: ConversationComposer.Body.self), 30)
    }

    private static func genericDepth(of type: Any.Type) -> Int {
        var depth = 0
        var deepest = 0
        for character in String(reflecting: type) {
            if character == "<" {
                depth += 1
                deepest = max(deepest, depth)
            } else if character == ">" {
                depth -= 1
            }
        }
        return deepest
    }
}
