import XCTest
import SwiftUI
import FleetUI
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence

/// Universal setup-prompt content tests + first-run hydration state tests.
///
/// The prompt is a versioned artifact that ships with the app: these tests
/// pin its SEMANTIC guarantees (OS/environment detection, non-destructive
/// inspection, supported gateway setup, secure phone-reachable connectivity,
/// credential hygiene, end-to-end verification, concise reply) and its
/// NEUTRALITY (no OS, distribution channel, or networking vendor is
/// prescribed — the prompt tells the executing Hermes to DETECT those).
/// Silently dropping a mission leg or baking in an environment assumption
/// fails the build.
@MainActor
final class OnboardingPromptTests: XCTestCase {

    // MARK: Mission coverage (every leg present)

    func testAllMissionLegsPresent() {
        for (index, keywords) in OnboardingPrompt.missionKeywords.enumerated() {
            for keyword in keywords {
                XCTAssertTrue(
                    OnboardingPrompt.text.contains(keyword),
                    "mission leg \(index + 1) missing keyword \"\(keyword)\" — a copy edit dropped a required mission element"
                )
            }
        }
    }

    /// Leg 1 — the prompt explicitly tells Hermes to DETECT the operating
    /// system and environment instead of assuming one.
    func testPromptRequiresEnvironmentDetection() {
        let text = OnboardingPrompt.text
        XCTAssertTrue(text.contains("detect"),
                      "the prompt must tell Hermes to detect its environment")
        XCTAssertTrue(text.contains("operating system"),
                      "OS detection must be explicit")
    }

    /// Legs 1/2 — existing state must be inspected and preserved before any
    /// modification (non-destructive).
    func testPromptRequiresInspectionBeforeModification() {
        let text = OnboardingPrompt.text
        XCTAssertTrue(text.contains("Inspect first"),
                      "inspection must come first")
        XCTAssertTrue(text.contains("Preserve working configuration"),
                      "working configuration must be preserved")
        XCTAssertTrue(text.contains("don't reinstall"))
    }

    /// Leg 2 — a SUPPORTED Fleet gateway derived from current documentation;
    /// no invented endpoints; honest unsupported-version handling.
    func testPromptRequiresSupportedGatewaySetup() {
        let text = OnboardingPrompt.text
        XCTAssertTrue(text.contains("gateway/server interface"))
        XCTAssertTrue(text.contains("supported"))
        XCTAssertTrue(text.contains("documentation"))
        XCTAssertTrue(text.contains("don't invent"))
    }

    /// Leg 3 — secure iPhone-reachable connectivity chosen from EXISTING
    /// infrastructure; no unilateral third-party enrollment.
    func testPromptRequiresSecurePhoneReachableConnectivity() {
        let text = OnboardingPrompt.text
        XCTAssertTrue(text.contains("iPhone must reach the gateway securely"))
        XCTAssertTrue(text.contains("safest"))
        XCTAssertTrue(text.contains("Don't enroll me in any new third-party service"))
    }

    /// Leg 4 — credential hygiene: scoped, least privilege, never logged or
    /// committed, no overwriting unrelated secrets.
    func testPromptRequiresCredentialHygiene() {
        let text = OnboardingPrompt.text
        XCTAssertTrue(text.contains("scoped"))
        XCTAssertTrue(text.contains("least privilege"))
        XCTAssertTrue(text.contains("logs"))
        XCTAssertTrue(text.contains("source control"))
        XCTAssertTrue(text.contains("don't overwrite unrelated secrets"))
    }

    /// Leg 5 — end-to-end verification from the phone's network path, not a
    /// local-only check.
    func testPromptRequiresEndToEndVerification() {
        let text = OnboardingPrompt.text
        XCTAssertTrue(text.contains("Verify end-to-end"))
        XCTAssertTrue(text.contains("same network path my phone will use"))
        XCTAssertTrue(text.contains("not just a local process check"))
    }

    /// Leg 6 — the reply returns exactly the connection information Fleet
    /// needs, with a pairing alternative.
    func testPromptReturnsConnectionInformationFleetNeeds() {
        let text = OnboardingPrompt.text
        XCTAssertTrue(text.contains("Reply with exactly"))
        XCTAssertTrue(text.contains("the URL"))
        XCTAssertTrue(text.contains("the username"))
        XCTAssertTrue(text.contains("the password"))
        XCTAssertTrue(text.contains("pairing steps"))
    }

    // MARK: Neutrality — no environment assumptions baked in

    /// The prompt must not prescribe an operating system, distribution
    /// channel, or networking vendor — and must not carry private
    /// deployment jargon (dogfood/RC/maintainer names).
    func testPromptContainsNoEnvironmentAssumptions() {
        XCTAssertTrue(
            OnboardingPrompt.containsNoEnvironmentAssumptions(),
            "prompt bakes in an environment assumption: \(OnboardingPrompt.forbiddenAssumptions.filter { OnboardingPrompt.text.contains($0) })"
        )
    }

    func testPromptDoesNotAssumeAppInstallMechanism() {
        // The setup agent prepares its MACHINE's gateway; it never installs
        // or updates the iPhone app. The prompt says so explicitly.
        let text = OnboardingPrompt.text
        XCTAssertTrue(text.contains("already installed on my phone"))
        XCTAssertTrue(text.contains("don't try to install or update the iPhone app"))
    }

    // MARK: Hygiene — no secrets, no private endpoints, no maintainer detail

    func testContainsNoSecretsOrEndpoints() throws {
        XCTAssertTrue(OnboardingPrompt.containsNoSecrets(),
                      "prompt contains a forbidden substring: \(OnboardingPrompt.forbiddenSubstrings.filter { OnboardingPrompt.text.contains($0) })")
    }

    func testNoMaintainerOrPrivateDetails() {
        // Belt-and-braces beyond the forbidden lists: no maintainer identity,
        // host, or private address shape may appear — the prompt is written
        // for a generic Hermes user (universal prompt, v4).
        let text = OnboardingPrompt.text
        for banned in ["tonysimons", "aiowa", "hermesfleet.gateway",
                       ".ts.net", "9120", "100.100.", "192.168."] {
            XCTAssertFalse(text.contains(banned), "prompt must not embed maintainer or per-user detail \"\(banned)\"")
        }
    }

    // MARK: Conciseness + versioning

    func testPromptIsConcise() {
        // A copyable onboarding prompt: bounded so it stays paste-friendly.
        XCTAssertLessThanOrEqual(OnboardingPrompt.wordCount, 300,
                                 "prompt is \(OnboardingPrompt.wordCount) words — trim toward ~250")
        XCTAssertGreaterThan(OnboardingPrompt.wordCount, 100,
                             "prompt too short to cover the mission")
    }

    func testVersionIsPositiveAndTextNonEmpty() {
        XCTAssertGreaterThan(OnboardingPrompt.version, 0)
        XCTAssertFalse(OnboardingPrompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: View wiring

    func testOnboardingViewInitializes() {
        // View-init smoke (same bar as FleetComponentsTests): the first-run
        // screen builds with its environment.
        let environment = TestEnvironments.empty()
        let view = GatewayOnboardingView(environment: environment)
        XCTAssertNotNil(view.body)
    }

    func testFirstRunSetupViewInitializes() {
        let view = FirstRunSetupView(environment: TestEnvironments.empty())
        XCTAssertNotNil(view.body)
    }

    func testSetupPromptSheetInitializes() {
        // C2: the Settings-hosted setup-prompt sheet builds standalone.
        let view = SetupPromptSheet()
        XCTAssertNotNil(view.body)
    }

    func testDocsURLIsHTTPSAndPointsAtDocs() throws {
        let url = OnboardingDocs.bootstrapURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertTrue(url.absoluteString.contains("hermes-agent.nousresearch.com/docs"))
    }

    // MARK: First-run hydration state model

    func testFreshEnvironmentStartsLoadingThenSettlesUnconfigured() async {
        // Zero-gateway hydrated state presents onboarding; the loading phase
        // exists FIRST so onboarding never flashes before hydration.
        let environment = TestEnvironments.empty()
        XCTAssertEqual(environment.hydrationPhase, .loading,
                       "a fresh runtime must start in .loading — onboarding must not flash before hydration")
        await environment.load()
        XCTAssertEqual(environment.hydrationPhase, .unconfigured,
                       "a hydrated empty registry must be .unconfigured (onboarding state)")
    }

    func testFirstGatewayRegistrationFlipsPhaseToConfigured() async throws {
        let environment = TestEnvironments.empty()
        await environment.load()
        XCTAssertEqual(environment.hydrationPhase, .unconfigured)
        _ = try await environment.addGateway(
            GatewayRegistration(
                id: GatewayID(rawValue: "first"),
                displayName: "First Server",
                endpoint: URL(string: "https://gateway.example.invalid:8642")!
            )
        )
        XCTAssertEqual(environment.hydrationPhase, .configured,
                       "registering the first gateway must end the onboarding state")
    }

    func testRemovingFinalGatewayReturnsToUnconfigured() async throws {
        // Deliberate product behavior: an empty registry returns to the
        // first-run setup experience (the registry is the onboarding truth).
        let environment = TestEnvironments.empty()
        await environment.load()
        let gateway = try await environment.addGateway(
            GatewayRegistration(
                id: GatewayID(rawValue: "only"),
                displayName: "Only Server",
                endpoint: URL(string: "https://gateway.example.invalid:8642")!
            )
        )
        XCTAssertEqual(environment.hydrationPhase, .configured)
        try await environment.removeGateway(gateway.id)
        XCTAssertEqual(environment.hydrationPhase, .unconfigured,
                       "removing the final gateway must return to the setup state")
    }

    func testConfiguredRelaunchSettlesConfiguredNotOnboarding() async {
        // Relaunch with a registered server: load() settles .configured —
        // onboarding must NOT reappear for a configured user.
        let environment = TestEnvironments.seeded()
        await environment.load()
        XCTAssertEqual(environment.hydrationPhase, .configured,
                       "a restored non-empty registry must settle .configured (no onboarding on relaunch)")
    }
}

/// Scripted environments for the first-run hydration state tests (same
/// construction pattern as the neighboring AppEnvironment suites).
@MainActor
private enum TestEnvironments {

    struct TestSessionList: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    final class TestHealthAccumulator: ConnectionHealthAccumulating, @unchecked Sendable {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    struct TestRosterSession: GatewayRosterSession {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] { [] }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    struct TestConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
    }

    static func make(seed: [GatewayRegistration]) -> AppEnvironment {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id)
            }
        )
        return AppEnvironment(
            registry: registry,
            roster: FleetRosterService(
                registry: registry,
                credentials: credentials,
                sessionFactory: { gateway, _ in
                    TestRosterSession(gatewayID: gateway.id)
                }
            ),
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in
                TestConnection(gatewayID: gateway.id)
            },
            health: TestHealthAccumulator(),
            seedRegistrations: seed
        )
    }

    /// Zero gateways anywhere (no seeds, empty registry).
    static func empty() -> AppEnvironment {
        make(seed: [])
    }

    /// One gateway registered (the relaunch-configured state).
    static func seeded() -> AppEnvironment {
        make(seed: [
            GatewayRegistration(
                id: GatewayID(rawValue: "workstation"),
                displayName: "Workstation",
                endpoint: URL(string: "https://gateway.example.invalid:8642")!
            )
        ])
    }
}
