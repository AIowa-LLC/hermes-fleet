import Foundation

/// A parsed, validated Hermes Fleet pairing invitation link:
///
///     https://<gateway-host>[:port]/pair#v=1&i=<invitation id>&s=<secret>
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
    public static let currentVersion = 1
    /// The only accepted path.
    public static let path = "/pair"
    static let maxLength = 2048

    /// `https://host[:port]` (no path), the gateway this invitation is for.
    public let origin: URL
    /// Public handle of the invitation (not a secret on its own).
    public let invitationID: String
    /// The single-use secret. Redacted everywhere it prints.
    public let secret: PairingInvitationSecret

    init(origin: URL, invitationID: String, secret: PairingInvitationSecret) {
        self.origin = origin
        self.invitationID = invitationID
        self.secret = secret
    }

    /// The host as it will be displayed and contacted.
    public var host: String { origin.host ?? "" }

    public var description: String { "PairingInvitationLink(host: \(host), secret: [REDACTED])" }
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
    public static func parse(_ text: String) throws -> PairingInvitationLink {
        try parse(text, policy: .publicDNSName)
    }

    /// Parse a link delivered by the system (Universal Link / open-URL).
    public static func parse(_ url: URL) throws -> PairingInvitationLink {
        try parse(url.absoluteString, policy: .publicDNSName)
    }

    static func parse(_ text: String, policy: HostPolicy) throws -> PairingInvitationLink {
        guard text.count <= maxLength * 4 else { throw ParseError.tooLong }
        let token = firstLinkToken(in: text)
        guard !token.isEmpty else { throw ParseError.notAPairingLink }
        guard token.count <= maxLength else { throw ParseError.tooLong }
        guard token.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x21 && $0.value < 0x7F }) else {
            // Control characters, spaces, and non-ASCII (look-alike hosts) never appear in a real link.
            throw ParseError.notAPairingLink
        }
        guard let components = URLComponents(string: token) else { throw ParseError.notAPairingLink }

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
        guard let versionText = fields["v"], let version = Int(versionText) else {
            throw ParseError.malformedFields
        }
        guard version == currentVersion else { throw ParseError.unsupportedVersion(version) }
        guard let id = fields["i"], isToken(id, 16...64),
              let secret = fields["s"], isToken(secret, 32...128) else {
            throw ParseError.malformedFields
        }

        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        if let port = components.port, port != 443 { origin.port = port }
        guard let originURL = origin.url else { throw ParseError.invalidHost }
        return PairingInvitationLink(
            origin: originURL, invitationID: id, secret: PairingInvitationSecret(secret))
    }

    /// Test seam for in-process servers (never reachable from production callers).
    static func parseForTesting(_ text: String) throws -> PairingInvitationLink {
        try parse(text, policy: .anyForTesting)
    }

    /// Whether `url` could be a pairing link, without validating it. Lets the app route
    /// an incoming URL to the pairing flow so that a malformed link gets a clear message.
    public static func looksLikePairingLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else { return false }
        return url.path == path
    }

    private static func firstLinkToken(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = trimmed.range(of: "https://", options: .caseInsensitive)
            ?? trimmed.range(of: "http://", options: .caseInsensitive)
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
