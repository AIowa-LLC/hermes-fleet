import XCTest
@testable import FleetUI

/// Refinement Phase 4: the first-run trust statement, and tripwires that keep
/// each of its claims true of the code.
final class RefinementPhase4Tests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func swiftSources(under relative: String) -> [(path: String, text: String)] {
        let root = repoRoot.appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map { (url.path, $0) }
            }
    }

    func testFirstScreenSaysTheFourThingsInOrder() {
        XCTAssertEqual(OnboardingTrustPoints.points.map(\.title),
                       ["Open source", "Your servers", "No account", "No middleman"])
    }

    /// "Open source": the link goes to the public repository, which ships a
    /// license file.
    func testOpenSourceClaimPointsAtTheLicensedRepository() throws {
        XCTAssertEqual(OnboardingTrustPoints.sourceURL.absoluteString,
                       "https://github.com/AIowa-LLC/hermes-fleet")
        let license = try String(contentsOf: repoRoot.appendingPathComponent("LICENSE"), encoding: .utf8)
        XCTAssertTrue(license.contains("MIT License"), "the copy says MIT-licensed")
    }

    /// "No middleman": no app code registers with the push relay. If the relay
    /// ships, this fails on purpose — revisit the first-run copy before
    /// changing this test.
    func testNoMiddlemanClaimHoldsWhileThePushRelayIsUnwired() {
        let offenders = (swiftSources(under: "Packages") + swiftSources(under: "HermesFleetApp"))
            .filter { !$0.path.contains("/Tests/") && $0.text.contains("RelayKeyID.generate(") }
            .map(\.path)
        XCTAssertEqual(offenders, [], "a relay in the connection path contradicts \"No middleman\"")
    }

    /// "Your password goes only to this server and isn't saved": owner sign-in
    /// posts to the server's own login and keeps only the session it returns.
    func testOwnerSignInPostsToTheServerAndKeepsNoPassword() throws {
        let client = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/FleetNetworking/Sources/FleetNetworking/OwnerEnrollmentClient.swift"),
            encoding: .utf8)
        XCTAssertTrue(client.contains("base.appendingPathComponent(\"auth/password-login\")"))
        let view = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/FleetUI/Sources/FleetUI/GatewayOnboardingView.swift"),
            encoding: .utf8)
        XCTAssertTrue(view.contains("password = \"\""), "the view clears the password after sign-in")
        // Within signIn itself: the password goes into the request body and
        // only the returned session cookie leaves the function.
        let start = try XCTUnwrap(client.range(of: "public func signIn("))
        let end = try XCTUnwrap(client.range(of: "public func approveTLSFirstUse("))
        let signIn = String(client[start.lowerBound..<end.lowerBound]).lowercased()
        XCTAssertTrue(signIn.contains("return .sessioncookie("))
        for persistence in ["keychain", "userdefaults", "save", "store"] {
            XCTAssertFalse(signIn.contains(persistence), "signIn must not persist anything (\(persistence))")
        }
    }
}
