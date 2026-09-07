import Foundation

/// Agent bootstrap prompt shown from Settings > Agent Setup Prompt and from
/// the empty-gateways onboarding screen.
///
/// The prompt is versioned with the app. Bump `version` whenever the install
/// path, credential scheme, or network guidance changes. Tests pin its mission
/// coverage and safety properties rather than exact prose.
public enum OnboardingPrompt {

    /// Current mission revision. Version 3 uses Wi-Fi sideloading and a
    /// user-owned HTTPS gateway endpoint.
    public static let version: Int = 3

    /// Full copyable bootstrap prompt.
    public static let text: String = """
        I'm setting up Hermes Fleet, the iPhone app for my Hermes fleet. Set it up \
        end-to-end and reply with exactly what I need.

        1. Install: I sideload Hermes Fleet from my Mac over Wi-Fi — no TestFlight. \
        If my phone needs a newer build, build and install it.
        2. Network: expose MY Hermes gateway at an HTTPS endpoint I control (for \
        example a TLS tunnel to my own domain). Confirm it answers from the open \
        internet with a valid certificate, and that no raw LAN, tailnet, or \
        cleartext-http address is handed to the app.
        3. Credentials: create a scoped app credential for Hermes Fleet with \
        zero-print hygiene — write values only to a 0600 file or the reply, never \
        to logs.
        4. Verify: confirm the endpoint answers an authentication request from \
        the network path my phone will use.
        5. Reply with exactly: the URL, the username, the password, and one line \
        telling me to open Hermes Fleet on my phone and add the gateway.
        """

    /// Mission-coverage keyword sets. Tests assert each is present so copy
    /// edits cannot silently drop a required onboarding step.
    public static let missionKeywords: [[String]] = [
        ["Wi-Fi", "sideload"],
        ["HTTPS", "endpoint", "I control"],
        ["HTTPS", "certificate"],
        ["scoped", "credential"],
        ["0600", "logs"],
        ["URL", "username", "password"],
        ["authentication request"],
    ]

    /// Substrings that must never appear in the prompt. The bootstrap mission
    /// describes a user-owned reachable HTTPS origin rather than embedding a
    /// private address or credential shape.
    public static let forbiddenSubstrings: [String] = [
        "http://",
        "100.100.",
        "192.168.", "10.", "127.0.0.1",
        "password:", "token:",
    ]

    /// Word count used by the conciseness test.
    public static var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Mechanical hygiene check exercised by tests.
    public static func containsNoSecrets() -> Bool {
        forbiddenSubstrings.allSatisfy { !text.contains($0) }
    }
}
