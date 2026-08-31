import Foundation
import Security

/// Abstraction over the Security framework `SecItem*` calls a Keychain store
/// makes, so the store's upsert / delete logic can be tested with injected
/// failures without touching a live keychain (CI stays hermetic).
///
/// The production implementation (`LiveKeychainSession`) is a thin pass-through
/// to `SecItem*`; tests inject a scripted double that records calls and can
/// force any status.
public protocol KeychainSession: Sendable {
    func add(_ query: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
    func copyMatching(_ query: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus
}

/// Production `KeychainSession` — a direct pass-through to the Security
/// framework (no behavior of its own).
public struct LiveKeychainSession: KeychainSession {
    public init() {}

    public func add(_ query: CFDictionary) -> OSStatus {
        SecItemAdd(query, nil)
    }

    public func update(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributesToUpdate)
    }

    public func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }

    public func copyMatching(_ query: CFDictionary, _ result: inout CFTypeRef?) -> OSStatus {
        SecItemCopyMatching(query, &result)
    }
}
