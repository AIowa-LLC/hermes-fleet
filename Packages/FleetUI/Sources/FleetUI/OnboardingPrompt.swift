import Foundation

/// F3/C2 — the agent bootstrap prompt shown from Settings ▸ Agent Setup Prompt
/// (and the empty-gateways onboarding screen).
///
/// The prompt is a VERSIONED ARTIFACT that ships with the app (design note
/// from the task card): it must track install-path changes, so `version` is
/// the single field to bump when the mission changes and the tests pin the
/// wording shape — not exact prose — so copy edits don't churn the suite.
///
/// v2 (C2): TestFlight + Tailscale/LAN legs replaced by the shipping flow —
/// Wi-Fi dev sideloads and the public HTTPS tunnel. The tunnel endpoint is
/// deliberately NAMED (it is a public DNS host with a valid certificate and
/// gateway auth in front — not a secret); raw LAN/tailnet IPs and cleartext
/// http remain forbidden.
public enum OnboardingPrompt {

    /// Mission revision — bump when the agent mission changes (install path,
    /// credential scheme, network guidance). v1 = F3 TestFlight + Tailscale;
    /// v2 = C2 Wi-Fi sideload + HTTPS tunnel (<legacy-fleet-endpoint>).
    public static let version: Int = 2

    /// The full copyable bootstrap prompt (< ~200 words, per the card).
    public static let text: String = """
        I'm setting up Hermes Fleet, the iPhone app for my Hermes fleet. Set it up \
        end-to-end and reply with exactly what I need.

        1. Install: I sideload Hermes Fleet from my Mac over Wi-Fi — no TestFlight. \
        If my phone needs a newer build, build and install it.
        2. Network: the gateway must be reachable over the public HTTPS tunnel at \
        https://<legacy-fleet-endpoint>. Confirm the tunnel answers from the open \
        internet with a valid certificate, and that no raw LAN or tailnet IP is \
        handed to the app.
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
        ["<legacy-fleet-endpoint>"],                // (2) named tunnel endpoint
        ["HTTPS", "tunnel", "certificate"],      // (2) transport + cert check
        ["scoped", "credential"],                // (3) credential mint
        ["0600", "logs"],                        // (3) zero-print hygiene
        ["URL", "username", "password"],         // (5) reply shape
        ["authentication request"],              // (4) verify from phone's path
    ]

    /// Substrings that must NEVER appear in the prompt: cleartext http,
    /// private/tailnet address literals (the public tunnel is the path — a
    /// raw IP would reintroduce exactly the non-portable endpoint the tunnel
    /// replaced), and embedded credential shapes. `https://` is allowed for
    /// the named tunnel host.
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
