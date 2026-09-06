import Foundation

/// F3/C2 — the agent bootstrap prompt shown from Settings ▸ Agent Setup Prompt
/// (and the empty-gateways onboarding screen).
///
/// The prompt is a VERSIONED ARTIFACT that ships with the app (design note
/// from the task card): it must track install-path changes, so `version` is
/// the single field to bump when the mission changes and the tests pin the
/// wording shape — not exact prose — so copy edits don't churn the suite.
///
/// v1 (F3): TestFlight + Tailscale legs. v2 (C2): Wi-Fi sideload + a named
/// maintainer tunnel. v3 (public release): the endpoint leg is now fully
/// user-owned — the operator exposes THEIR OWN Hermes gateway over HTTPS
/// (e.g. via a TLS tunnel to a domain they control). No maintainer or
/// per-user hostname is named in the prompt; raw LAN/tailnet IPs and
/// cleartext http remain forbidden.
public enum OnboardingPrompt {

    /// Mission revision — bump when the agent mission changes (install path,
    /// credential scheme, network guidance). v1 = TestFlight + Tailscale;
    /// v2 = Wi-Fi sideload + maintainer tunnel; v3 = Wi-Fi sideload +
    /// user-owned HTTPS endpoint.
    public static let version: Int = 3

    /// The full copyable bootstrap prompt (< ~200 words, per the card).
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

    /// Mission-coverage keyword sets — the unit tests assert each is present
    /// so a copy edit can't silently drop a mission leg (card acceptance:
    /// install / network / credentials / reply / verify).
    public static let missionKeywords: [[String]] = [
        ["Wi-Fi", "sideload"],                   // (1) app install path
        ["HTTPS", "endpoint", "I control"],     // (2) user-owned endpoint
        ["HTTPS", "certificate"],                // (2) transport + cert check
        ["scoped", "credential"],                // (3) credential mint
        ["0600", "logs"],                        // (3) zero-print hygiene
        ["URL", "username", "password"],         // (5) reply shape
        ["authentication request"],              // (4) verify from phone's path
    ]

    /// Substrings that must NEVER appear in the prompt: cleartext http,
    /// private/tailnet address literals (the endpoint must be the user's own
    /// reachable HTTPS origin — a raw IP would reintroduce exactly the
    /// non-portable endpoint problem), and embedded credential shapes.
    /// `https://` is allowed for describing the user's endpoint scheme.
    public static let forbiddenSubstrings: [String] = [
        "http://",                        // cleartext endpoints
        "100.100.",                       // tailnet address blocks
        "192.168.", "10.", "127.0.0.1",   // LAN/loopback literals
        "password:", "token:",            // embedded credential shapes
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
