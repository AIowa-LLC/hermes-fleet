import Foundation

/// Agent setup prompt shown from Settings ▸ Set Up Another Server and from
/// the first-run onboarding gate (zero configured gateways).
///
/// The prompt is versioned with the app. Bump `version` whenever the mission
/// shape changes. Tests pin its semantic guarantees (OS detection, non-
/// destructive inspection, supported gateway setup, secure connectivity,
/// credential hygiene, end-to-end verification, concise reply) and its
/// neutrality (no operating system, distribution channel, or networking
/// vendor is prescribed) rather than exact prose.
public enum OnboardingPrompt {

    /// Current prompt revision. Version 4 is universal: it tells the user's
    /// Hermes Agent to DETECT its environment (OS, install, network) instead
    /// of assuming one, and prepares the machine's Hermes gateway for the
    /// iPhone app — it never assumes how the app itself was installed.
    public static let version: Int = 4

    /// Full copyable setup prompt.
    public static let text: String = """
        I'm setting up Hermes Fleet, the iPhone app for controlling my Hermes \
        machines. Prepare THIS computer's Hermes gateway so my phone can \
        connect, then reply with exactly what I need.

        1. Inspect first: detect this machine's operating system, how Hermes \
        is installed and launched, its version, any existing gateway or \
        remote-access configuration, and any existing secure networking (VPN, \
        overlay network, tunnel, reverse proxy). Preserve working \
        configuration — don't reinstall or replace anything that already works.
        2. Gateway: determine the gateway/server interface for remote control \
        that my installed Hermes version supports, using its current \
        documentation. Prefer existing supported configuration; don't invent \
        endpoints. If this Hermes version can't support a phone client, tell \
        me what must change before modifying anything.
        3. Network: my iPhone must reach the gateway securely. Choose the \
        safest option that fits what's already here — an existing HTTPS \
        endpoint, private network, or tunnel. Don't enroll me in any new \
        third-party service that creates an account or public exposure \
        without asking, and don't alter existing routes or firewalls.
        4. Credentials: create or reuse a scoped credential for Hermes \
        Fleet — least privilege. Never print it into logs, never commit it \
        to source control, don't overwrite unrelated secrets.
        5. Verify end-to-end: confirm the endpoint answers an authenticated \
        request from the same network path my phone will use — not just a \
        local process check.
        6. Reply with exactly: the URL, the username, the password (or the \
        pairing steps I need instead), and one line on which connection \
        method you chose.

        Hermes Fleet is already installed on my phone — don't try to install \
        or update the iPhone app.
        """

    /// Semantic guarantees — each group of phrases must be present so copy
    /// edits cannot silently drop a required mission leg.
    public static let missionKeywords: [[String]] = [
        // 1. Inspect first — detect, don't assume.
        ["detect", "operating system"],
        // Preserve existing state; non-destructive.
        ["Preserve working configuration"],
        // 2. Supported gateway from current documentation.
        ["supported", "documentation"],
        // 3. Secure phone-reachable connectivity, chosen from existing
        //    infrastructure; no unilateral third-party enrollment.
        ["iPhone must reach the gateway securely", "safest"],
        // 4. Scoped least-privilege credential with hygiene.
        ["scoped", "least privilege"],
        // 5. End-to-end verification from the phone's network path.
        ["same network path my phone will use"],
        // 6. Concise reply with exactly the connection values.
        ["the URL", "the username", "the password"],
    ]

    /// Substrings that must never appear in the prompt: no credentials,
    /// private/loopback IP literals, or credential-shaped key/value text.
    public static let forbiddenSubstrings: [String] = [
        "http://",
        "100.100.",
        "192.168.", "10.", "127.0.0.1",
        "password:", "token:",
    ]

    /// Environment- or maintainer-specific terms the universal prompt must
    /// NOT bake in as assumptions. The prompt may name an option generically
    /// ("a tunnel", "an overlay network") but never prescribes a vendor,
    /// OS, or distribution channel. Case-sensitive by design: "macOS" and
    /// "Tailscale" are vendor names; lowercase generic words are allowed.
    public static let forbiddenAssumptions: [String] = [
        "sideload", "Wi-Fi", "TestFlight", "Mac", "macOS", "Windows",
        "Linux", "tailnet", "Tailscale", "Xcode", "Homebrew", "systemd",
        "launchd", "PowerShell", "Cloudflare", "dogfood", "Tony",
        "Apple Squad",
    ]

    /// Word count used by the conciseness test.
    public static var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Mechanical hygiene check exercised by tests.
    public static func containsNoSecrets() -> Bool {
        forbiddenSubstrings.allSatisfy { !text.contains($0) }
    }

    /// Neutrality check exercised by tests: no environment assumption is
    /// baked into the prompt.
    public static func containsNoEnvironmentAssumptions() -> Bool {
        forbiddenAssumptions.allSatisfy { !text.contains($0) }
    }
}
