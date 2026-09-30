import Foundation

/// The non-sensitive, redacted fleet summary the app shares with extensions
/// (widgets, Live Activity, Notification Service Extension name cache).
///
/// What it may contain — and nothing else:
/// - an opaque per-gateway `handle` (random, app-assigned; never a hostname,
///   never a `GatewayID` derived from an endpoint, never a credential);
/// - a short display label (the user's own gateway name, or "Gateway N" when
///   `contentHidden`);
/// - coarse counts (running / needs attention / online) and timestamps;
/// - a schema version and the `contentHidden` flag.
///
/// What it must never contain: transcript text, commands, hostnames or URLs,
/// tokens or pins, session titles, bot names, approval details. The type simply
/// has no field for them; `validate()` bounds what the fields can hold.
///
/// Decode compatibility: decoding ignores unknown keys, and `ExtensionSnapshotStore`
/// reads `schemaVersion` first, so an older extension reading a newer file fails
/// closed (`unsupportedSchemaVersion`) instead of mis-parsing it.
public struct ExtensionSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let maximumGatewayCount = 32
    public static let maximumLabelLength = 40
    public static let maximumCount = 9_999
    static let handleLengthRange = 16...64

    public struct Gateway: Codable, Sendable, Equatable {
        /// Opaque per-gateway reference (see `OpaqueGatewayHandle`).
        public var handle: String
        /// Display label: user-chosen gateway name, or "Gateway N" when hidden.
        public var displayLabel: String
        public var runningCount: Int
        public var needsAttentionCount: Int
        public var onlineCount: Int
        /// When the app last observed this gateway's state.
        public var updatedAt: Date?

        public init(
            handle: String,
            displayLabel: String,
            runningCount: Int,
            needsAttentionCount: Int,
            onlineCount: Int,
            updatedAt: Date? = nil
        ) {
            self.handle = handle
            self.displayLabel = displayLabel
            self.runningCount = runningCount
            self.needsAttentionCount = needsAttentionCount
            self.onlineCount = onlineCount
            self.updatedAt = updatedAt
        }
    }

    public var schemaVersion: Int
    public var generatedAt: Date
    /// True when labels were replaced with "Gateway N" (App Lock enabled) and
    /// consumers must not render anything the user named.
    public var contentHidden: Bool
    public var gateways: [Gateway]

    public init(
        schemaVersion: Int = ExtensionSnapshot.currentSchemaVersion,
        generatedAt: Date,
        contentHidden: Bool,
        gateways: [Gateway]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.contentHidden = contentHidden
        self.gateways = gateways
    }

    /// Check the structural bounds the writer enforces and the reader re-checks.
    /// Throws `ExtensionSnapshotError.invalid` with a fixed, non-echoing reason
    /// (snapshot content never reaches error text).
    public func validate() throws {
        guard gateways.count <= Self.maximumGatewayCount else {
            throw ExtensionSnapshotError.invalid(.tooManyGateways)
        }
        var seen = Set<String>()
        for (index, gateway) in gateways.enumerated() {
            guard OpaqueGatewayHandle.isValid(gateway.handle) else {
                throw ExtensionSnapshotError.invalid(.badHandle)
            }
            guard seen.insert(gateway.handle).inserted else {
                throw ExtensionSnapshotError.invalid(.duplicateHandle)
            }
            guard Self.isValidLabel(gateway.displayLabel) else {
                throw ExtensionSnapshotError.invalid(.badLabel)
            }
            for count in [gateway.runningCount, gateway.needsAttentionCount, gateway.onlineCount]
            where !(0...Self.maximumCount).contains(count) {
                throw ExtensionSnapshotError.invalid(.countOutOfRange)
            }
            if contentHidden, gateway.displayLabel != Self.hiddenLabel(forIndex: index) {
                throw ExtensionSnapshotError.invalid(.hiddenSnapshotCarriesLabels)
            }
        }
    }

    /// The label used in place of names when content is hidden (1-based).
    public static func hiddenLabel(forIndex index: Int) -> String {
        "Gateway \(index + 1)"
    }

    static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= maximumLabelLength else { return false }
        return !label.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// A copy with every label replaced by "Gateway N" and `contentHidden` set.
    public func redactedForLock() -> ExtensionSnapshot {
        var copy = self
        copy.contentHidden = true
        copy.gateways = gateways.enumerated().map { index, gateway in
            var hidden = gateway
            hidden.displayLabel = Self.hiddenLabel(forIndex: index)
            return hidden
        }
        return copy
    }
}

/// Bounded, redaction-aware construction of a snapshot from app state. The app
/// target's writer feeds this; the pure function is unit tested here.
public enum ExtensionSnapshotBuilder {
    public struct GatewayInput: Sendable, Equatable {
        public var handle: String
        public var displayName: String
        public var runningCount: Int
        public var needsAttentionCount: Int
        public var onlineCount: Int
        public var observedAt: Date?

        public init(
            handle: String,
            displayName: String,
            runningCount: Int,
            needsAttentionCount: Int,
            onlineCount: Int,
            observedAt: Date? = nil
        ) {
            self.handle = handle
            self.displayName = displayName
            self.runningCount = runningCount
            self.needsAttentionCount = needsAttentionCount
            self.onlineCount = onlineCount
            self.observedAt = observedAt
        }
    }

    /// Build a snapshot. When `appLockEnabled`, names are replaced by
    /// "Gateway N" and `contentHidden` is set (the redaction-when-locked rule).
    /// Counts are clamped and labels sanitized/truncated; inputs beyond the
    /// gateway cap are dropped.
    public static func make(
        gateways: [GatewayInput],
        appLockEnabled: Bool,
        now: Date
    ) -> ExtensionSnapshot {
        let bounded = gateways.prefix(ExtensionSnapshot.maximumGatewayCount)
        let entries = bounded.enumerated().map { index, input in
            ExtensionSnapshot.Gateway(
                handle: input.handle,
                displayLabel: appLockEnabled
                    ? ExtensionSnapshot.hiddenLabel(forIndex: index)
                    : sanitizedLabel(input.displayName, fallbackIndex: index),
                runningCount: clamp(input.runningCount),
                needsAttentionCount: clamp(input.needsAttentionCount),
                onlineCount: clamp(input.onlineCount),
                updatedAt: input.observedAt.map(wholeSeconds)
            )
        }
        return ExtensionSnapshot(
            generatedAt: wholeSeconds(now),
            contentHidden: appLockEnabled,
            gateways: Array(entries)
        )
    }

    /// The on-disk format carries whole seconds (ISO 8601), so truncate here and
    /// a written snapshot always reads back equal.
    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, 0), ExtensionSnapshot.maximumCount)
    }

    /// Trim, replace control characters/newlines with spaces, collapse runs of
    /// whitespace, and cap the length. An empty result falls back to "Gateway N".
    static func sanitizedLabel(_ name: String, fallbackIndex: Int) -> String {
        let scalars = name.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                ? " " : Character(scalar)
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let capped = String(collapsed.prefix(ExtensionSnapshot.maximumLabelLength))
            .trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? ExtensionSnapshot.hiddenLabel(forIndex: fallbackIndex) : capped
    }
}

/// A random, app-assigned, non-secret reference to a gateway that is safe to put
/// in a snapshot and in push registration metadata.
///
/// `GatewayID` cannot be used for this: it may be derived from the gateway's
/// host and port. The handle is 16 random bytes as unpadded base64url (22
/// characters). It is NOT the secret `relay_key_id` (a different value with a
/// different purpose); never reuse one for the other.
public enum OpaqueGatewayHandle {
    private static let randomByteCount = 16

    public static func generate() -> String? {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: randomByteCount)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Base64url charset only (no dots, colons, or slashes, so a hostname or
    /// endpoint-derived id can never pass) and a bounded length.
    public static func isValid(_ value: String) -> Bool {
        guard ExtensionSnapshot.handleLengthRange.contains(value.count) else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"):
                return true
            default:
                return false
            }
        }
    }
}
