import Foundation

/// A parsed, validated Hermes Fleet pairing invitation link:
///
///     https://<gateway-host>[:port]/pair#v=1&i=<invitation id>&s=<secret>
///     https://<gateway-host>[:port]/pair#v=2&i=<id>&s=<secret>&k=<spki pin>
///     <app-scheme>://pair#v=2&i=<id>&s=<secret>&k=<spki pin>&o=<base64url https origin>
///
/// Version 1 links are redeemed directly. Version 2 links never redeem on their own: they
/// create a pending request the owner must approve by its match code (see
/// `docs/universal-login.md`), and carry the SHA-256 of the server's TLS public key (`k`)
/// so the first contact can be pinned even when the certificate is not system-trusted.
///
/// The link is a short-lived, single-use, origin-scoped capability issued by an
/// authenticated owner on the gateway (never an existing username, password or
/// long-lived token). The secret travels only in the URL FRAGMENT, which no
/// browser or proxy ever sends to a server.
///
/// Opening, parsing or previewing a link has no side effect: nothing is
/// consumed or approved until the person confirms and the app redeems it.
///
/// Safety invariants:
/// - the destination must be `https` on a real DNS name (no IP literal,
///   `localhost`, single-label host, user-info or non-ASCII/IDN host), so a
///   publicly trusted certificate can exist for it and the host shown to the
///   person is exactly the host contacted;
/// - the printable forms are redacted (`description` shows the host only), so
///   a link can never reach a log, a crash report or an error message;
/// - it is deliberately NOT `Codable`.
public struct PairingInvitationLink: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The direct-redeem link version.
    public static let legacyVersion = 1
    /// The approval-based link version (requires a `k` pin).
    public static let approvalVersion = 2
    public static let currentVersion = approvalVersion
    /// Host of the app-scheme form (`<scheme>://pair#…`).
    public static let appSchemeHost = "pair"
    /// The only accepted path.
    public static let path = "/pair"
    static let maxLength = 2048

    /// `https://host[:port]` (no path), the gateway this invitation is for.
    public let origin: URL
    /// Public handle of the invitation (not a secret on its own).
    public let invitationID: String
    /// The single-use secret. Redacted everywhere it prints.
    public let secret: PairingInvitationSecret
    /// Link format version: 1 (direct redeem) or 2 (owner approval).
    public let version: Int
    /// SHA-256 of the server's TLS public key (SPKI) the link vouches for. Present exactly
    /// for version 2. Public key material, not a secret.
    public let pin: SPKIFingerprint?

    init(origin: URL, invitationID: String, secret: PairingInvitationSecret,
         version: Int = PairingInvitationLink.legacyVersion, pin: SPKIFingerprint? = nil) {
        self.origin = origin
        self.invitationID = invitationID
        self.secret = secret
        self.version = version
        self.pin = pin
    }

    /// Whether the owner must approve this phone's request (version 2) rather than the
    /// invitation being redeemed directly (version 1).
    public var requiresApproval: Bool { version >= Self.approvalVersion }

    /// The host as it will be displayed and contacted.
    public var host: String { origin.host ?? "" }

    public var description: String {
        "PairingInvitationLink(host: \(host), v\(version), secret: [REDACTED], pin: \(pin == nil ? "none" : "[REDACTED]"))"
    }
    public var debugDescription: String { description }

    // MARK: Errors

    public enum ParseError: Error, Sendable, Equatable {
        /// Not a Hermes pairing link at all (or not parseable as a URL).
        case notAPairingLink
        /// The link is not `https`.
        case insecureScheme
        /// The host is not an acceptable public DNS name.
        case invalidHost
        /// User-info, a query, or a non-`/pair` path: not something an issuer produces.
        case unexpectedComponents
        /// A pairing link of a version this app does not understand.
        case unsupportedVersion(Int)
        /// Required fragment fields are missing, duplicated or malformed.
        case malformedFields
        /// Longer than any real link.
        case tooLong
    }

    /// What destinations are acceptable. Production always uses `.publicDNSName`.
    enum HostPolicy: Sendable {
        case publicDNSName
        /// Tests only: lets an in-process or loopback server stand in for a gateway.
        case anyForTesting
    }

    // MARK: Parsing

    /// Parse a link from text a person pasted or a QR code carried. Surrounding
    /// whitespace is ignored, and when the text holds other words the first
    /// `https://` token is used (people paste "Here: https://...").
    ///
    /// - Parameter appURLScheme: the app's own URL scheme. When given, the app-scheme form
    ///   `<scheme>://pair#…&o=<origin>` is accepted too (the `/pair` web page opens the app
    ///   with it).
    public static func parse(_ text: String, appURLScheme: String? = nil) throws -> PairingInvitationLink {
        try parse(text, policy: .publicDNSName, appURLScheme: appURLScheme)
    }

    /// Parse a link delivered by the system (Universal Link / open-URL).
    public static func parse(_ url: URL, appURLScheme: String? = nil) throws -> PairingInvitationLink {
        try parse(url.absoluteString, policy: .publicDNSName, appURLScheme: appURLScheme)
    }

    static func parse(
        _ text: String, policy: HostPolicy, appURLScheme: String? = nil
    ) throws -> PairingInvitationLink {
        guard text.count <= maxLength * 4 else { throw ParseError.tooLong }
        let token = firstLinkToken(in: text, appURLScheme: appURLScheme)
        guard !token.isEmpty else { throw ParseError.notAPairingLink }
        guard token.count <= maxLength else { throw ParseError.tooLong }
        guard token.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x21 && $0.value < 0x7F }) else {
            // Control characters, spaces, and non-ASCII (look-alike hosts) never appear in a real link.
            throw ParseError.notAPairingLink
        }
        guard let components = URLComponents(string: token) else { throw ParseError.notAPairingLink }

        if let appURLScheme, components.scheme?.lowercased() == appURLScheme.lowercased() {
            return try parseAppSchemeLink(components, policy: policy)
        }
        switch components.scheme?.lowercased() {
        case "https": break
        case "http": throw ParseError.insecureScheme
        default: throw ParseError.notAPairingLink
        }
        guard components.user == nil, components.password == nil,
              components.query == nil, components.path == path else {
            throw ParseError.unexpectedComponents
        }
        guard let host = components.host?.lowercased(), isAcceptableHost(host, policy: policy) else {
            throw ParseError.invalidHost
        }
        if let port = components.port, !(1...65535).contains(port) { throw ParseError.invalidHost }

        let fields = try fragmentFields(components.fragment)
        guard fields["o"] == nil else { throw ParseError.malformedFields }   // origin travels only in the app-scheme form
        let (version, id, secret, pin) = try credentialFields(fields)

        guard let originURL = makeOrigin(host: host, port: components.port) else { throw ParseError.invalidHost }
        return PairingInvitationLink(
            origin: originURL, invitationID: id, secret: PairingInvitationSecret(secret),
            version: version, pin: pin)
    }

    /// `<scheme>://pair#v=2&i=…&s=…&k=…&o=<base64url https origin>`. The origin is decoded
    /// and held to exactly the same host rules as an https link.
    private static func parseAppSchemeLink(
        _ components: URLComponents, policy: HostPolicy
    ) throws -> PairingInvitationLink {
        guard components.host?.lowercased() == appSchemeHost, components.user == nil, components.password == nil,
              components.query == nil, components.port == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ParseError.unexpectedComponents
        }
        let fields = try fragmentFields(components.fragment)
        let (version, id, secret, pin) = try credentialFields(fields)
        guard version == approvalVersion else { throw ParseError.malformedFields }   // v1 never used this form
        guard let encoded = fields["o"], let originData = base64URLDecode(encoded),
              let originText = String(data: originData, encoding: .utf8),
              originText.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x21 && $0.value < 0x7F }),
              let origin = URLComponents(string: originText) else {
            throw ParseError.malformedFields
        }
        switch origin.scheme?.lowercased() {
        case "https": break
        case "http": throw ParseError.insecureScheme
        default: throw ParseError.malformedFields
        }
        guard origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/" else {
            throw ParseError.unexpectedComponents
        }
        guard let host = origin.host?.lowercased(), isAcceptableHost(host, policy: policy) else {
            throw ParseError.invalidHost
        }
        if let port = origin.port, !(1...65535).contains(port) { throw ParseError.invalidHost }
        guard let originURL = makeOrigin(host: host, port: origin.port) else { throw ParseError.invalidHost }
        return PairingInvitationLink(
            origin: originURL, invitationID: id, secret: PairingInvitationSecret(secret),
            version: version, pin: pin)
    }

    private static func makeOrigin(host: String, port: Int?) -> URL? {
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        if let port, port != 443 { origin.port = port }
        return origin.url
    }

    /// Validates `v`, `i`, `s` and `k` together: v1 has no pin; v2 requires a canonical one.
    private static func credentialFields(
        _ fields: [String: String]
    ) throws -> (version: Int, id: String, secret: String, pin: SPKIFingerprint?) {
        guard let versionText = fields["v"], let version = Int(versionText) else {
            throw ParseError.malformedFields
        }
        guard version == legacyVersion || version == approvalVersion else {
            throw ParseError.unsupportedVersion(version)
        }
        guard let id = fields["i"], isToken(id, 16...64),
              let secret = fields["s"], isToken(secret, 32...128) else {
            throw ParseError.malformedFields
        }
        var pin: SPKIFingerprint?
        if version == approvalVersion {
            guard let raw = fields["k"], let parsed = parsePin(raw) else { throw ParseError.malformedFields }
            pin = parsed
        } else if fields["k"] != nil {
            throw ParseError.malformedFields     // a v1 link has no pin; do not guess what it means
        }
        return (version, id, secret, pin)
    }

    /// Exactly 43 base64url characters (no padding) decoding to a 32-byte SHA-256 digest.
    /// Non-canonical trailing bits are rejected so one key has one spelling.
    static func parsePin(_ text: String) -> SPKIFingerprint? {
        guard text.utf8.count == 43, let data = base64URLDecode(text), data.count == 32,
              base64URLEncode(data) == text else { return nil }
        return SPKIFingerprint(sha256Digest: data)
    }

    /// Strict unpadded base64url (alphabet `A-Za-z0-9-_`, no `=`).
    public static func base64URLDecode(_ text: String) -> Data? {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-" || $0 == "_"
        }) else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        switch standard.count % 4 {
        case 0: break
        case 2: standard += "=="
        case 3: standard += "="
        default: return nil
        }
        return Data(base64Encoded: standard)
    }

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Test seam for in-process servers (never reachable from production callers).
    static func parseForTesting(_ text: String) throws -> PairingInvitationLink {
        try parse(text, policy: .anyForTesting)
    }

    /// Whether `url` could be a pairing link, without validating it. Lets the app route
    /// an incoming URL to the pairing flow so that a malformed link gets a clear message.
    public static func looksLikePairingLink(_ url: URL, appURLScheme: String? = nil) -> Bool {
        let scheme = url.scheme?.lowercased()
        if let appURLScheme, scheme == appURLScheme.lowercased() {
            return url.host?.lowercased() == appSchemeHost
        }
        guard scheme == "https" || scheme == "http" else { return false }
        return url.path == path
    }

    private static func firstLinkToken(in text: String, appURLScheme: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var start = trimmed.range(of: "https://", options: .caseInsensitive)
            ?? trimmed.range(of: "http://", options: .caseInsensitive)
        if let appURLScheme,
           let app = trimmed.range(of: "\(appURLScheme)://\(appSchemeHost)", options: .caseInsensitive),
           start == nil || app.lowerBound < start!.lowerBound {
            start = app
        }
        let tail = start.map { trimmed[$0.lowerBound...] } ?? trimmed[...]
        return String(tail.prefix { !$0.isWhitespace })
    }

    private static func fragmentFields(_ fragment: String?) throws -> [String: String] {
        guard let fragment, !fragment.isEmpty else { throw ParseError.malformedFields }
        var fields: [String: String] = [:]
        for pair in fragment.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { throw ParseError.malformedFields }
            let key = String(parts[0]), value = String(parts[1])
            guard fields[key] == nil else { throw ParseError.malformedFields }   // duplicates are ambiguous
            fields[key] = value
        }
        return fields
    }

    private static func isToken(_ text: String, _ length: ClosedRange<Int>) -> Bool {
        length.contains(text.count) && text.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-" || $0 == "_"
        }
    }

    /// A real DNS name: ASCII letters/digits/hyphen labels, at least two labels, not an IP
    /// literal, not `localhost`, no trailing dot games.
    static func isAcceptableHost(_ host: String, policy: HostPolicy) -> Bool {
        if policy == .anyForTesting { return !host.isEmpty }
        guard !host.isEmpty, host.count <= 253, !host.hasSuffix(".") else { return false }
        if host.contains(":") || host.contains("[") || host.contains("%") { return false }   // IPv6 / zone ids
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }                                       // single-label
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        // Dotted-quad (or any all-numeric) hosts are IP literals, not names.
        if labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return false }
        guard let last = labels.last, !last.allSatisfy(\.isNumber) else { return false }
        for label in labels {
            guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
            guard label.unicodeScalars.allSatisfy({
                ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-"
            }) else { return false }
        }
        return true
    }
}

/// The invitation secret. Printing it yields `[REDACTED]`; the raw value is read
/// explicitly by the one component that sends it to the gateway.
public struct PairingInvitationSecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { "[REDACTED]" }
    public var debugDescription: String { "PairingInvitationSecret(redacted)" }
}
