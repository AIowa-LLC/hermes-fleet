import XCTest
import FleetCore
@testable import HermesFleetApp

/// ATS configuration drift guard.
///
/// Earlier development builds used per-host `NSExceptionDomains` entries for
/// private gateway addresses. Public builds intentionally ship without those
/// maintainer-specific exceptions.
///
/// This suite locks the public configuration so future plist changes cannot
/// silently reintroduce private topology:
/// - `NSExceptionDomains` must be absent;
/// - `NSAllowsLocalNetworking` must remain for local-network gateways;
/// - an optional `FleetDefaultEndpoint` must be a public HTTPS origin.
final class ATSExceptionDriftTests: XCTestCase {

    private var info: [String: Any] {
        let bundle = Bundle(for: type(of: self))
        guard let dict = Bundle.main.infoDictionary ?? bundle.infoDictionary else {
            XCTFail("app Info.plist missing")
            return [:]
        }
        return dict
    }

    func testNoExceptionDomains() {
        XCTAssertNil(info["NSAppTransportSecurity"].flatMap { ($0 as? [String: Any])?["NSExceptionDomains"] },
                     "NSExceptionDomains must stay stripped — raw-IP/private-host ATS exceptions leak fleet topology into the shipped binary")
    }

    func testLocalNetworkingRemainsAllowed() throws {
        let ats = try XCTUnwrap(info["NSAppTransportSecurity"] as? [String: Any],
                                "NSAppTransportSecurity missing from app Info.plist")
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true,
                       "NSAllowsLocalNetworking must stay true for true-LAN gateway connects")
    }

    func testDefaultEndpointIsOptionalPublicHTTPS() throws {
        let raw = (info["FleetDefaultEndpoint"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty {
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
