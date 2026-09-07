import Foundation

/// Known gateway capability flags (spec §5.5: "capability detection over
/// version guessing"; §12 model "capabilities"). Decoding is tolerant —
/// unknown strings are preserved, not dropped, so a newer gateway's flags
/// degrade gracefully instead of failing the surface.
public enum GatewayCapability: String, Hashable, Sendable, CaseIterable {
    /// The gateway expects the client to send periodic pings (`gateway.ping`).
    case heartbeat
    /// The gateway streams change notifications (`change_events`).
    case changeEvents = "change_events"
    /// The gateway supports per-session event replay (spec §9).
    case replay

    /// Map a raw wire string onto a known capability, or `nil` when unknown.
    public init?(rawWireValue: String) {
        self.init(rawValue: rawWireValue)
    }
}

/// The capability surface of a gateway: known capabilities plus any unknown
/// flags the gateway advertised (preserved verbatim, spec §5.5 tolerant
/// detection). A value object — never fabricated; derived from authoritative
/// signals only (spec §14).
public struct GatewayCapabilities: Hashable, Sendable {
    public let known: Set<GatewayCapability>
    public let unknown: Set<String>

    public init(known: Set<GatewayCapability> = [], unknown: Set<String> = []) {
        self.known = known
        self.unknown = unknown
    }

    /// Tolerant decode from the wire's `Set<String>` capability flags
    /// (e.g. adopted from `gateway.ready`).
    public init(strings: Set<String>) {
        var known: Set<GatewayCapability> = []
        var unknown: Set<String> = []
        for raw in strings {
            if let capability = GatewayCapability(rawWireValue: raw) {
                known.insert(capability)
            } else {
                unknown.insert(raw)
            }
        }
        self.known = known
        self.unknown = unknown
    }

    public var isEmpty: Bool { known.isEmpty && unknown.isEmpty }

    /// Every string this surface represents (known raw values + unknown).
    public var allStrings: Set<String> {
        var result = unknown
        for capability in known {
            result.insert(capability.rawValue)
        }
        return result
    }

    public func contains(_ capability: GatewayCapability) -> Bool {
        known.contains(capability)
    }
}
