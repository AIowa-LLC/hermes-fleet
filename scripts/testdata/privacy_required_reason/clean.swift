import Foundation

// UserDefaults, stat, fstat, lstat, fstatat, getattrlist, and activeInputModes
// are names in this comment, not calls in the production source.
let explanation = "UserDefaults stat fstat lstat fstatat getattrlist systemUptime statfs activeInputModes"
let unrelated = "creationDate modificationDate volumeTotalCapacityKey"
private func stat(_ label: String, _ value: String) {}
stat("local helper", "not an Apple API")
_ = [explanation, unrelated]
