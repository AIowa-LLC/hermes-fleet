import Foundation
import FleetCore

#if DEBUG && targetEnvironment(simulator)
/// Synthetic onboarding responses. Never compiled into a physical-device build.
actor ScriptedOwnerEnrollment: OwnerEnrollmentProviding {
    private let scenario: String
    private var trusted = false
    private var origin = URL(string: "https://onboarding.fixture.test")!
    private let fingerprint = SPKIFingerprint(rawBytes: Array(repeating: 0x42, count: 32))

    init(scenario: String = ProcessInfo.processInfo.environment["HERMES_FLEET_ONBOARDING_SCENARIO"] ?? "success") {
        self.scenario = scenario
    }

    func discoverProviders(at address: URL) async throws -> [OwnerIdentityProvider] {
        guard address.scheme == "https" else { throw OwnerEnrollmentError.insecureTransport }
        origin = address
        switch scenario {
        case "unavailable": throw OwnerEnrollmentError.unreachable
        case "rate-limit": throw OwnerEnrollmentError.rateLimited(retryAfterSeconds: 60)
        case "pin-change": throw OwnerEnrollmentError.tlsPinMismatch
        case "tls-first-use" where !trusted: throw OwnerEnrollmentError.tlsFirstUse(fingerprint)
        case "unsupported":
            return [OwnerIdentityProvider(id: "oauth-fixture", displayName: "Browser sign-in", supportsPassword: false)]
        default:
            return [OwnerIdentityProvider(id: "basic", displayName: "Username & Password", supportsPassword: true)]
        }
    }

    func signIn(at address: URL, providerID: String, username: String, password: String) async throws -> OwnerAuthorization {
        if scenario == "delayed-sign-in" { try await Task.sleep(for: .seconds(10)) }
        guard providerID == "basic", username == "owner", password == "synthetic-password",
              scenario != "bad-password" else { throw OwnerEnrollmentError.unauthorized }
        return .sessionCookie(name: "hermes_session_at", value: "synthetic-owner-session")
    }

    func approveTLSFirstUse(at address: URL, fingerprint: SPKIFingerprint) async throws {
        guard fingerprint == self.fingerprint else { throw OwnerEnrollmentError.tlsPinMismatch }
        trusted = true
    }

    func inspectConnection(at address: URL, authorization: OwnerAuthorization) async throws -> OwnerConnectionMetadata {
        OwnerConnectionMetadata(gatewayID: GatewayID(rawValue: scenario == "duplicate" ? "workstation" : "onboarding-fixture"), displayName: "Hermes Server",
                                origin: origin, scopes: ["fleet:operator"], enrollmentVersion: 1)
    }

    func enrollDevice(at address: URL, authorization: OwnerAuthorization, deviceName: String?, deviceModel: String?) async throws -> OwnerEnrolledDevice {
        if scenario == "delayed-enroll" { try await Task.sleep(for: .seconds(10)) }
        if scenario == "keychain-failure" { throw OwnerEnrollmentError.credentialStorageFailed }
        return OwnerEnrolledDevice(gatewayID: GatewayID(rawValue: "onboarding-fixture"), displayName: "Hermes Server",
                                   deviceID: "0123456789abcdef0123456789abcdef", scopes: ["fleet:operator"])
    }

    func cancelEnrollment(at address: URL, authorization: OwnerAuthorization, deviceID: String, gatewayID: GatewayID) async throws {}
}
#endif
