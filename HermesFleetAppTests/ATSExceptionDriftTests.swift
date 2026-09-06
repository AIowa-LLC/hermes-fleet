import XCTest
import FleetCore
@testable import HermesFleetApp

/// F2 (t_b678fb38) — ATS convergence drift guard for the HTTPS tunnel.
///
/// F1 history: the app connected to private Hermes gateways over cleartext
/// `http://` and needed per-host `NSExceptionDomains` entries — raw private
/// IPs and the tailnet hostname compiled into every shipped binary, leaking
/// Tony's home network topology into the IPA. F2 converges the fleet on the
/// public HTTPS tunnel and strips every
/// raw-IP/private-host exception.
///
/// This suite locks the converged state so a future plist rewrite cannot
/// silently reintroduce private topology:
/// - `NSExceptionDomains` must be ABSENT (zero raw-IP / private entries);
/// - `NSAllowsLocalNetworking` must remain (true-LAN `http://` gateways);
/// - the `FleetDefaultEndpoint` migration value must be a PUBLIC https
///   origin (scheme https, a host that is not private/loopback, no port).
final class ATSExceptionDriftTests: XCTestCase {

    private var info: [String: Any] {
        let bundle = Bundle(for: type(of: self))
        // Hosted tests run in the app process: the app's Info.plist is the
        // main bundle. (Bundle.main == the installed app under test.)
        guard let dict = Bundle.main.infoDictionary ?? bundle.infoDictionary else {
            XCTFail("app Info.plist missing")
            return [:]
        }
        return dict
    }

    /// Zero per-domain exceptions — the QA gate-3 contract (extracted binary
    /// Info.plist carries no raw-IP exceptions / private topology).
    func testNoExceptionDomains() {
        XCTAssertNil(info["NSAppTransportSecurity"].flatMap { ($0 as? [String: Any])?["NSExceptionDomains"] },
                     "NSExceptionDomains must stay stripped — raw-IP/private-host ATS exceptions leak fleet topology into the shipped binary")
    }

    /// Local networking stays allowed for true-LAN http:// gateways.
    func testLocalNetworkingRemainsAllowed() throws {
        let ats = try XCTUnwrap(info["NSAppTransportSecurity"] as? [String: Any],
                                "NSAppTransportSecurity missing from app Info.plist")
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true,
                       "NSAllowsLocalNetworking must stay true for true-LAN gateway connects")
    }

    /// The converged default endpoint must be a public HTTPS origin — never
    /// a private IP, loopback, or tailnet host, and never cleartext.
    func testDefaultEndpointIsOptionalPublicHTTPS() throws {
        let raw = (info["FleetDefaultEndpoint"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty {
            // Default public configuration: NO compiled endpoint — every user
            // connects to their own HTTPS-reachable gateway.
            return
        }
        let url = try XCTUnwrap(URL(string: raw), "FleetDefaultEndpoint is not a URL: \(raw)")
        XCTAssertEqual(url.scheme?.lowercased(), "https",
                       "FleetDefaultEndpoint must be HTTPS (cleartext defaults are forbidden)")
        let host = try XCTUnwrap(url.host, "FleetDefaultEndpoint has no host")
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost(host),
                       "FleetDefaultEndpoint must be a PUBLIC host — private topology is forbidden in shipped configuration")
        XCTAssertFalse(host.hasSuffix(".ts.net"),
                       "tailnet hostnames are private topology and must not ship")
        XCTAssertNil(url.port, "FleetDefaultEndpoint should be a standard-port origin")
    }
}
