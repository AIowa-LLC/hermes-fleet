import XCTest
@testable import HermesFleetApp

/// F1 (t_10831eec) — ATS exception drift guard for the two-gateway fleet.
///
/// P0-5 history: the app connects to private Hermes gateways over cleartext
/// `http://` (basic-auth session flow). ATS silently blocks such connections
/// unless the host is listed under `NSAppTransportSecurity.NSExceptionDomains`
/// in the app's Info.plist — the failure mode is an invisible "connect fails
/// with no error surfaced". This suite locks the required exception entries so
/// a future project regeneration or plist rewrite cannot silently drop them.
final class ATSExceptionDriftTests: XCTestCase {

    /// The parsed ATS dictionary from the app target's Info.plist.
    private var ats: [String: Any] {
        let bundle = Bundle(for: type(of: self))
        // Hosted tests run in the app process: the app's Info.plist is the
        // main bundle. (Bundle.main == the installed app under test.)
        guard let info = Bundle.main.infoDictionary,
              let dict = info["NSAppTransportSecurity"] as? [String: Any] else {
            XCTFail("NSAppTransportSecurity missing from app Info.plist")
            return [:]
        }
        return dict
    }

    private func exceptionAllowsInsecureHTTP(_ host: String) -> Bool {
        guard let domains = ats["NSExceptionDomains"] as? [String: Any] else {
            return false
        }
        guard let entry = domains[host] as? [String: Any] else { return false }
        let allows = entry["NSExceptionAllowsInsecureHTTPLoads"] as? Bool ?? false
        return allows
    }

    /// Mac gateway #1 — tailnet surface (P0-5/T2). Must stay excepted.
    func testMacTailnetHostException() {
        XCTAssertTrue(exceptionAllowsInsecureHTTP("<tailnet-ip>"),
                      "ATS exception for Mac tailnet <tailnet-ip> drifted — gateway #1 cleartext connect would silently fail")
    }

    /// Mac gateway #1 — LAN surface.
    func testMacLANHostException() {
        XCTAssertTrue(exceptionAllowsInsecureHTTP("<lan-ip>"),
                      "ATS exception for Mac LAN <lan-ip> drifted")
    }

    /// Arch gateway #2 — tailnet IP surface (F1). Must stay excepted or the
    /// multi-gateway bring-up fails exactly like P0-5 did.
    func testArchTailnetIPException() {
        XCTAssertTrue(exceptionAllowsInsecureHTTP("<tailnet-ip>"),
                      "ATS exception for Arch tailnet <tailnet-ip> missing — gateway #2 cleartext connect would silently fail")
    }

    /// Arch gateway #2 — tailnet MagicDNS hostname surface (F1).
    func testArchTailnetHostnameException() {
        XCTAssertTrue(exceptionAllowsInsecureHTTP("<private-host>"),
                      "ATS exception for Arch MagicDNS host missing — hostname-form endpoint would silently fail")
    }
}
