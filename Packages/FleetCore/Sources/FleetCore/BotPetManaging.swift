import Foundation

/// Pet catalog seam (#9 §2): profile-scoped read operations for the Bot
/// avatar Pet picker, routed through the Bot's OWN gateway/profile (the
/// concrete client rides the same per-gateway transport as
/// `BotProfileManaging`).
///
/// Read-only by design: selecting a pet as an avatar NEVER calls
/// pet.select/pet.disable/pet.remove/pet.rename/pet.scale and never
/// writes `display.pet.*` — those control the animated mascot, a separate
/// feature. The only write in the whole flow is the avatar asset itself
/// through the normal `profiles.set_asset` path on Save.
public protocol BotPetManaging: Sendable {
    /// `pet.gallery` for a profile. `localOnly: true` loads
    /// installed/generated pets immediately (the manifest prefetches in
    /// the background on the gateway); the full Petdex catalog hydrates
    /// via a second non-local call.
    func petGallery(profile: String, localOnly: Bool) async throws -> HermesPetGallery

    /// `pet.thumb` for a profile + slug → idle-frame PNG bytes.
    /// `sourceURL` carries the catalog `spritesheetUrl` (nil for
    /// installed/generated pets without a remote sheet — the gateway
    /// renders those from its own installed sheet).
    ///
    /// - Throws: `BotPetError.unsupported` when the gateway answers
    ///   JSON-RPC method-not-found (Pets are UNAVAILABLE on that gateway —
    ///   not a transient failure).
    func petThumbnail(profile: String, slug: String, sourceURL: String?) async throws -> Data
}

/// Typed Pet surface failures (#9): unsupported-capability (method-not-
/// found → Pets unavailable, NOT retryable) stays distinct from transient
/// RPC/network failures (retryable).
public enum BotPetError: Error, Equatable, Sendable, LocalizedError {
    /// The gateway does not implement the Pet RPC surface at all — render
    /// the Pets unavailable state; do not auto-retry.
    case petsUnavailable(String)
    /// The gateway answered `ok:false` for a thumbnail (e.g. the pet has
    /// no usable sheet / the remote fetch failed there).
    case thumbnailUnavailable(slug: String)
    /// The reply could not be decoded into the typed contract.
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .petsUnavailable(let s): return s
        case .thumbnailUnavailable(let slug):
            return "No thumbnail is available for “\(slug)”."
        case .malformed(let s): return "malformed pet payload: \(s)"
        }
    }
}

/// Default implementation: surfaces without Pet support report the
/// unavailable state instead of pretending (fail closed, honest).
public extension BotPetManaging {
    func petGallery(profile: String, localOnly: Bool) async throws -> HermesPetGallery {
        throw BotPetError.petsUnavailable("Hermes Pets are not available on this gateway.")
    }

    func petThumbnail(profile: String, slug: String, sourceURL: String?) async throws -> Data {
        throw BotPetError.petsUnavailable("Hermes Pets are not available on this gateway.")
    }
}
