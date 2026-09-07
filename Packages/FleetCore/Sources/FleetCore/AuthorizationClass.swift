/// Authorization ceiling for a task, mirroring the fleet authorization
/// lattice: `none < readOnly < reversibleWrite < highImpact`.
///
/// The client enforces fail-closed behavior at this boundary as
/// defense-in-depth; the server remains authoritative.
public enum AuthorizationClass: String, CaseIterable, Sendable, Codable {
    case readOnly
    case reversibleWrite
    case highImpact
}
