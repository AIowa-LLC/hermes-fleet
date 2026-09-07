import XCTest
@testable import FleetCore

/// S3 (B2) — cleartext-warning classifier unit tests.
///
/// The gateway form must warn before saving an `http://` endpoint whose host
/// is NOT a private or loopback address. This suite locks the pure,
/// network-free classifier `PrivateNetwork.isPrivateOrLoopbackHost(_:)`:
///   - RFC1918 IPv4 (10/8, 172.16/12, 192.168/16) → private
///   - loopback (127/8 IPv4, ::1 IPv6, `localhost`) → private
///   - mDNS `.local` names → private
///   - everything else (public IPv4, public hostnames that resolve later) → NOT private
/// The conservative default for an unresolvable bare hostname is NOT private
/// (the warning shows) because we cannot prove it is private without DNS.
final class PrivateNetworkClassifierTests: XCTestCase {

    // MARK: RFC1918 private IPv4

    func testRFC1918PrivateIPv4IsPrivate() {
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("10.0.0.1"))
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("10.255.255.255"))
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("172.16.0.1"))
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("172.31.255.255"))
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("192.168.1.1"))
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("192.168.255.255"))
    }

    func testRFC1918BoundaryIsPublic() {
        // Just outside the RFC1918 blocks.
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("11.0.0.1"))
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("172.15.255.255"))
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("172.32.0.1"))
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("192.169.0.1"))
    }

    // MARK: Loopback

    func testIPv4LoopbackIsPrivate() {
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("127.0.0.1"))
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("127.0.0.2"))
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("127.255.255.254"))
    }

    func testIPv6LoopbackIsPrivate() {
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("::1"))
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("0:0:0:0:0:0:0:1"))
    }

    func testLocalhostHostnameIsPrivate() {
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("localhost"))
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("LOCALHOST"))
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost(" localhost "))
    }

    // MARK: mDNS .local names

    func testDotLocalNamesArePrivate() {
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("hermes.local"))
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("workstation.local"))
        XCTAssertTrue(PrivateNetwork.isPrivateOrLoopbackHost("gateway.local."))
    }

    // MARK: Public addresses

    func testPublicIPv4IsNotPrivate() {
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("8.8.8.8"))
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("1.1.1.1"))
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("203.0.113.7"))
        // RFC 6598 CGNAT 100.64/10 is NOT RFC1918 — treated as public here
        // (a Tailscale endpoint still deserves the cleartext warning).
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("100.64.0.1"))
    }

    // MARK: Hostname that resolves later

    func testBareHostnameResolvingLaterIsNotPrivate() {
        // A public hostname we cannot resolve at parse time must NOT be
        // classified private — the form warning is the conservative default.
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("gateway.example.com"))
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("hermes-node"))
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("my-hermes-gateway"))
    }

    // MARK: Malformed / edge inputs

    func testMalformedHostIsNotPrivate() {
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost(""))
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("not an ip"))
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("999.1.1.1"))
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("192.168.1"))
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("192.168.1.1.1"))
        XCTAssertFalse(PrivateNetwork.isPrivateOrLoopbackHost("127.0.0.1.9"))
    }
}
