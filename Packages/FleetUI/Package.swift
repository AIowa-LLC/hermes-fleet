// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FleetUI",
    platforms: [
        .iOS(.v26),
        .macOS(.v14) // host-side build convenience only; the product targets iOS
    ],
    products: [
        .library(name: "FleetUI", targets: ["FleetUI"])
    ],
    dependencies: [
        .package(path: "../FleetCore"),
        .package(path: "../FleetSecurity"),
        .package(path: "../FleetPersistence"),
        // Issue #5: keep the streaming Markdown implementation private to
        // FleetUI. This is the immutable commit for the v0.7.0 tag. SwiftPM
        // rejects the upstream exact-version requirement because that tag's
        // manifest also depends on HighlightSwift by an unversioned revision;
        // the tag commit is the reproducible v0.7.0 equivalent pin. The
        // Fleet-owned wrapper is the only API surface used by the rest of
        // the app.
        .package(url: "https://github.com/microsoft/SwiftStreamingMarkdown.git", revision: "5f7c04e0558df6146f90d482edb62cb456986bda")
    ],
    targets: [
        .target(name: "FleetUI", dependencies: [
            "FleetCore",
            .product(name: "SwiftStreamingMarkdown", package: "SwiftStreamingMarkdown"),
            // FleetSecurity and FleetPersistence are declared now to pin the
            // intended dependency direction; M0 does not yet consume them.
            //
            // FleetNetworking is INTENTIONALLY NOT a dependency: SwiftUI must
            // never depend on JSON-RPC / WebSocket plumbing (M0 hard scope
            // guard). The transport seam (`HermesTransport`) lives in FleetCore
            // and is wired by the composition root only.
            "FleetSecurity",
            "FleetPersistence"
        ], resources: [
            // V7: the FleetWingMark identity asset (white-wing lock/splash
            // mark) + FleetEmptyState artwork, package-local so FleetUI
            // resolves it via Bundle.module.
            .process("Resources")
        ])
    ]
)
