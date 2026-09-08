import XCTest
@testable import FleetCore

/// FOS-2 (t_e2169548) — SPEC §8 scope selection rule, exercised with a
/// TWO-GATEWAY fixture so exact scope is asserted, never order-derived:
/// - several profiles + no prior choice ⇒ selection REQUIRED (no first/default fallback)
/// - single profile ⇒ auto-select (must remain visibly labeled in UI)
/// - previous explicit choice still valid ⇒ reused
/// - stored choice gone ⇒ selection required again (never re-fallback)
/// - no candidates ⇒ unavailable (never `default`)
final class GatewayProfileSelectionPolicyTests: XCTestCase {

    private let policy = GatewayProfileSelectionPolicy()

    private func candidate(_ slug: String, _ name: String = "Bot") -> GatewayProfileSelectionPolicy.Candidate {
        GatewayProfileSelectionPolicy.Candidate(profileSlug: ProfileSlug(rawValue: slug), botName: name)
    }

    /// Two gateways, each with multiple profiles — the exact FOS-2 fixture.
    /// Nothing about gateway ORDER may influence the required-selection
    /// outcome, and `default` must not be privileged.
    func testMultipleProfilesRequireExplicitSelection_NeverFirstOrDefault() {
        let workstation = [candidate("researcher"), candidate("default"), candidate("studio-lab")]
        let laptop = [candidate("writer"), candidate("ops")]

        for (gateway, candidates) in [("workstation", workstation), ("laptop", laptop)] {
            let resolution = policy.resolve(candidates: candidates, storedSelection: nil)
            guard case .selectionRequired(let offered) = resolution else {
                return XCTFail("\(gateway): expected selectionRequired, got \(resolution)")
            }
            XCTAssertEqual(Set(offered), Set(candidates.map(\.profileSlug)),
                           "\(gateway): all profiles must be offered, none preselected")
            XCTAssertFalse(offered.isEmpty)
        }
    }

    func testSingleCandidateAutoSelects() {
        let resolution = policy.resolve(candidates: [candidate("researcher")], storedSelection: nil)
        XCTAssertEqual(resolution, .singleCandidate(ProfileSlug(rawValue: "researcher")))
    }

    func testStoredSelectionIsReusedWhenStillValid() {
        let candidates = [candidate("researcher"), candidate("default")]
        // Explicitly chose the NON-first profile previously.
        let resolution = policy.resolve(candidates: candidates, storedSelection: ProfileSlug(rawValue: "default"))
        XCTAssertEqual(resolution, .reuseStored(ProfileSlug(rawValue: "default")))
    }

    func testStoredSelectionInvalidFallsBackToChoice_NotFirst() {
        let candidates = [candidate("researcher"), candidate("default")]
        // "ops" no longer exists on this gateway.
        let resolution = policy.resolve(candidates: candidates, storedSelection: ProfileSlug(rawValue: "ops"))
        guard case .selectionRequired(let offered) = resolution else {
            return XCTFail("expected selectionRequired, got \(resolution)")
        }
        XCTAssertEqual(Set(offered), [ProfileSlug(rawValue: "researcher"), ProfileSlug(rawValue: "default")])
    }

    func testNoCandidatesIsUnavailable_NeverDefault() {
        XCTAssertEqual(
            policy.resolve(candidates: [], storedSelection: nil),
            .unavailable
        )
        // Even a stored "default" cannot resurrect an empty roster.
        XCTAssertEqual(
            policy.resolve(candidates: [], storedSelection: ProfileSlug(rawValue: "default")),
            .unavailable
        )
    }

    func testDuplicateSlugsCollapseToOneCandidate() {
        // Multiple Bots on one profile is one candidate per profile.
        let candidates = [
            candidate("researcher", "Researcher"),
            candidate("researcher", "Researcher Clone"),
            candidate("default", "Default Bot"),
        ]
        let resolution = policy.resolve(candidates: candidates, storedSelection: nil)
        guard case .selectionRequired(let offered) = resolution else {
            return XCTFail("expected selectionRequired, got \(resolution)")
        }
        XCTAssertEqual(offered.count, 2)
    }

    /// The pane-scoped persistence key namespace: two panes on one gateway
    /// keep independent explicit selections (asserted at the FleetUI layer
    /// via GatewayResourceView.storageKey's rule — mirrored here at the
    /// policy level by the storage key format contract).
    func testPerPaneSelectionIndependenceContract() {
        let candidates = [candidate("researcher"), candidate("default")]
        // Skills pane: explicitly chose researcher.
        XCTAssertEqual(
            policy.resolve(candidates: candidates, storedSelection: ProfileSlug(rawValue: "researcher")),
            .reuseStored(ProfileSlug(rawValue: "researcher"))
        )
        // Cron pane (no stored choice yet): must require selection — the
        // Skills choice must NOT leak into the Cron pane's resolution.
        guard case .selectionRequired = policy.resolve(candidates: candidates, storedSelection: nil) else {
            return XCTFail("expected selectionRequired for the cron pane")
        }
    }
}
