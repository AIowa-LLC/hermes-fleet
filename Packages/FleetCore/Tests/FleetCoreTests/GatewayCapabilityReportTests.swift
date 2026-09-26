import XCTest
@testable import FleetCore

/// P1 (RC-84) — gateway capability report policy: state mapping, honesty
/// invariants (never `supported` without evidence), and the summary line.
final class GatewayCapabilityReportTests: XCTestCase {

    private func evidence(
        advertised: Set<String> = [],
        groupsCreate: GroupsCreateCapability = .unknown,
        rosterOutcome: GatewayRosterOutcome? = nil,
        roomLinkNegotiated: Bool? = nil,
        observed: [GatewayCapabilityFeature: CapabilityAvailability] = [:]
    ) -> GatewayCapabilityEvidence {
        GatewayCapabilityEvidence(
            advertisedCapabilities: advertised,
            groupsCreate: groupsCreate,
            rosterOutcome: rosterOutcome,
            roomLinkNegotiated: roomLinkNegotiated,
            observed: observed)
    }

    private func state(
        _ feature: GatewayCapabilityFeature,
        _ evidence: GatewayCapabilityEvidence
    ) -> CapabilityAvailability {
        GatewayCapabilityReport.availability(for: feature, evidence: evidence)
    }

    // MARK: - Chats / Bots (roster evidence)

    func testLoadedRosterSupportsChatsAndBots() {
        let e = evidence(rosterOutcome: .loaded(profileCount: 3))
        XCTAssertEqual(state(.chats, e), .supported)
        XCTAssertEqual(state(.bots, e), .supported)
    }

    func testLoadedRosterWithZeroProfilesStillSupports() {
        let e = evidence(rosterOutcome: .loaded(profileCount: 0))
        XCTAssertEqual(state(.bots, e), .supported,
                       "a gateway with zero profiles still answered — capability, not configuration")
    }

    func testFailedRosterMakesChatsUnavailableWithDetail() {
        let e = evidence(rosterOutcome: .failed(status: .offline, detail: "connection refused"))
        guard case .unavailable(let reason) = state(.chats, e) else {
            return XCTFail("failed roster must map to unavailable")
        }
        XCTAssertEqual(reason, "connection refused")
    }

    func testFailedRosterWithoutDetailUsesStatusCopy() {
        let e = evidence(rosterOutcome: .failed(status: .authenticationRequired, detail: nil))
        guard case .unavailable(let reason) = state(.bots, e) else {
            return XCTFail("failed roster must map to unavailable")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("authentication"))
    }

    func testNeverCheckedRosterStaysUnknown() {
        guard case .unknown(let reason) = state(.chats, evidence()) else {
            return XCTFail("no roster outcome must stay unknown")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - Groups (probe evidence)

    func testGroupsCreateProbeMapsBothDirections() {
        XCTAssertEqual(state(.groups, evidence(groupsCreate: .supported)), .supported)
        guard case .unsupported(let reason) = state(.groups, evidence(groupsCreate: .unsupported)) else {
            return XCTFail("definitive absence must be unsupported")
        }
        XCTAssertFalse(reason.isEmpty)
        guard case .unknown = state(.groups, evidence(groupsCreate: .unknown)) else {
            return XCTFail("unprobed groups must stay unknown")
        }
    }

    // MARK: - RoomLink (negotiation evidence)

    func testRoomLinkStates() {
        guard case .unknown = state(.roomLink, evidence()) else {
            return XCTFail("unnegotiated RoomLink must stay unknown")
        }
        XCTAssertEqual(state(.roomLink, evidence(roomLinkNegotiated: true)), .supported)
        guard case .unsupported = state(.roomLink, evidence(roomLinkNegotiated: false)) else {
            return XCTFail("failed negotiation must be unsupported")
        }
    }

    // MARK: - Recorded observations outrank structural evidence

    func testObservedOutranksStructuralEvidence() {
        let e = evidence(
            groupsCreate: .supported,
            observed: [.groups: .unavailable(reason: "last send failed")])
        XCTAssertEqual(state(.groups, e), .unavailable(reason: "last send failed"))
    }

    func testObservedSupportsUnobservedFeature() {
        let e = evidence(observed: [.kanban: .supported])
        XCTAssertEqual(state(.kanban, e), .supported)
    }

    // MARK: - Honesty: no evidence means no claim

    func testUnobservedAppFeaturesAreUnknownWithReason() {
        for feature in GatewayCapabilityFeature.allCases
        where ![.chats, .bots, .groups, .roomLink].contains(feature) {
            guard case .unknown(let reason) = state(feature, evidence()) else {
                return XCTFail("\(feature) must be unknown with no evidence")
            }
            XCTAssertFalse(reason.isEmpty, "\(feature) unknown must carry a reason")
        }
    }

    func testAdvertisedCapabilitiesAloneNeverSupportAFeatureRow() {
        // The advertised transport flags say nothing about app features —
        // heartbeats/change_events/replay must not light anything up.
        let e = evidence(advertised: ["heartbeat", "change_events", "replay"])
        for feature in [GatewayCapabilityFeature.reactions, .attachments, .imageGeneration,
                        .voice, .schedules, .skills, .memory, .kanban, .projects, .approvals] {
            guard case .unknown = state(feature, e) else {
                return XCTFail("\(feature) must not infer from transport flags")
            }
        }
    }

    // MARK: - Rows + summary + labels

    func testRowsCoverEveryFeatureInDeclarationOrder() {
        let rows = GatewayCapabilityReport.rows(evidence())
        XCTAssertEqual(rows.map(\.feature), GatewayCapabilityFeature.allCases)
    }

    func testSummaryCountsAndOmitsZeroStates() {
        let rows = GatewayCapabilityReport.rows(evidence(
            groupsCreate: .unsupported,
            rosterOutcome: .loaded(profileCount: 1)))
        XCTAssertEqual(GatewayCapabilityReport.summary(rows),
                       "2 supported · 1 not supported · 11 unknown")
    }

    func testSummaryEmptyForNoRows() {
        XCTAssertEqual(GatewayCapabilityReport.summary([]), "")
    }

    func testLabelsAreDistinctAndReasonOnlyForNonSupported() {
        XCTAssertEqual(CapabilityAvailability.supported.label, "Supported")
        XCTAssertNil(CapabilityAvailability.supported.reason)
        XCTAssertEqual(CapabilityAvailability.unsupported(reason: "no").label, "Not supported")
        XCTAssertEqual(CapabilityAvailability.unavailable(reason: "no").label, "Unavailable")
        XCTAssertEqual(CapabilityAvailability.unknown(reason: "no").label, "Unknown")
        XCTAssertEqual(CapabilityAvailability.unsupported(reason: "r").reason, "r")
        XCTAssertEqual(CapabilityAvailability.unavailable(reason: "r").reason, "r")
        XCTAssertEqual(CapabilityAvailability.unknown(reason: "r").reason, "r")

        let labels = Set([
            CapabilityAvailability.supported.label,
            CapabilityAvailability.unsupported(reason: "r").label,
            CapabilityAvailability.unavailable(reason: "r").label,
            CapabilityAvailability.unknown(reason: "r").label,
        ])
        XCTAssertEqual(labels.count, 4, "the four states must stay visibly distinct")
    }
}