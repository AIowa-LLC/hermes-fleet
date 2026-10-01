import XCTest

/// F3 boundary: FleetClientKit is the extension-safe layer. It may depend on
/// FleetCore and FleetSecurity only, and its sources may import only Foundation,
/// Security, OSLog, CryptoKit, FleetCore, and FleetSecurity. The same rule is
/// enforced repo-wide by `scripts/extension_boundary_guard.py` and by the hosted
/// `ModuleBoundaryTests`; this host-side copy fails fast in `swift test`.
final class KitBoundaryTests: XCTestCase {
    private static let allowedImports: Set<String> = [
        "Foundation", "Security", "OSLog", "CryptoKit", "FleetCore", "FleetSecurity",
    ]

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FleetClientKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // FleetClientKit
    }

    func testSourcesImportOnlyAllowedModules() throws {
        let sources = packageRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") || trimmed.hasPrefix("@testable import ")
                        || trimmed.hasPrefix("@_exported import ") else { continue }
                let module = trimmed.split(separator: " ").last.map(String.init) ?? ""
                XCTAssertTrue(Self.allowedImports.contains(module),
                              "\(url.lastPathComponent) imports '\(module)', outside the extension-safe allow-list")
            }
        }
        XCTAssertGreaterThan(scanned, 0)
    }

    func testPackageDependsOnlyOnCoreAndSecurity() throws {
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let dependencies = manifest.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(".package(path:") }
        XCTAssertEqual(dependencies.count, 2, "FleetClientKit links FleetCore and FleetSecurity only")
        for forbidden in ["FleetNetworking", "FleetUI", "FleetPersistence"] {
            XCTAssertFalse(manifest.contains("\"../\(forbidden)\""), "must not depend on \(forbidden)")
        }
    }
}
