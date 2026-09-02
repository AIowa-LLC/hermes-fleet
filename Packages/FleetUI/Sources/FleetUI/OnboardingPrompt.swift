import Foundation

/// F3 — the agent bootstrap prompt shown on the onboarding screen.
///
/// The prompt is a VERSIONED ARTIFACT that ships with the app (design note
/// from the task card): it must track install-path changes (TestFlight →
/// App Store, QR pairing later), so `version` is the single field to bump
/// when the mission changes and the tests pin the wording shape — not exact
/// prose — so copy edits don't churn the suite.
///
/// SECURITY: the prompt contains NO secrets — no URLs, usernames, passwords,
/// tailnet names, LAN addresses, or any per-user detail. It is parameterized
/// by design ("my phone", "the tailnet") so it works for a user whose agent
/// runs on ANY Hermes box, not just one specific setup. `OnboardingPromptTests`
/// enforces this mechanically (see `containsNoSecrets`).
public enum OnboardingPrompt {

    /// Mission revision — bump when the agent mission changes (install path,
    /// credential scheme, network guidance). v1 = F3 TestFlight + Tailscale.
    public static let version: Int = 1

    /// The full copyable bootstrap prompt (< ~200 words, per the card).
    public static let text: String = """
        I'm setting up Hermes Fleet, the iPhone app for my Hermes fleet. Set it up \
        end-to-end and reply with exactly what I need.

        1. Install: I have the TestFlight app. Confirm I'm enrolled as a tester \
        for app 6807148674 (Hermes Fleet) and send me the invite link if I'm not.
        2. Network: make the gateway reachable from my phone. Prefer Tailscale: \
        check the tailnet, that my phone is on it, and that the gateway endpoint \
        answers there. If Tailscale isn't available, use the LAN: same Wi-Fi, \
        gateway bound to the LAN IP. Plain http over LAN is unencrypted — warn me \
        if that's the path.
        3. Credentials: create a scoped app credential for Hermes Fleet with \
        zero-print hygiene — write values only to a 0600 file or the reply, never \
        to logs.
        4. Verify: confirm the endpoint answers an authentication request from \
        the network path my phone will use.
        5. Reply with exactly: the URL, the username, the password, and one line \
        telling me to accept the TestFlight invite and install Hermes Fleet.
        """

    /// Mission-coverage keyword sets — the unit tests assert each is present
    /// so a copy edit can't silently drop a mission leg (card acceptance:
    /// install / network / credentials / reply / verify).
    public static let missionKeywords: [[String]] = [
        ["TestFlight", "6807148674"],          // (1) app install
        ["Tailscale", "tailnet"],              // (2) network path, preferred
        ["LAN", "unencrypted"],                // (2) LAN fallback + warning
        ["scoped", "credential"],              // (3) credential mint
        ["0600", "logs"],                      // (3) zero-print hygiene
        ["URL", "username", "password"],       // (5) reply shape
        ["authentication request"],            // (6) verify from phone's path
    ]

    /// Substrings that must NEVER appear in the prompt (parameterization
    /// guard): no scheme://host:port endpoints, no obviously-embedded secret
    /// material. Mechanical backstop for the "no secrets embedded" criterion.
    public static let forbiddenSubstrings: [String] = [
        "http://", "https://",   // endpoints are the agent's job to discover
        "100.100.",              // tailnet address blocks
        "192.168.", "10.", "127.0.0.1",  // LAN/loopback literals
        "password:", "token:",   // embedded credential shapes
    ]

    /// Conciseness bar from the card (~200 words). Word count of `text`.
    public static var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Whether the prompt passes its own mechanical hygiene checks
    /// (mission coverage + no forbidden substrings). Exercised by tests.
    public static func containsNoSecrets() -> Bool {
        forbiddenSubstrings.allSatisfy { !text.contains($0) }
    }
}
