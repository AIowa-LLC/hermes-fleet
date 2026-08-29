// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FleetUI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14) // host-side build convenience only; the product targets iOS
    ],
    products: [
        .library(name: "FleetUI", targets: ["FleetUI"])
    ],
    dependencies: [
        .package(path: "../FleetCore"),
        .package(path: "../FleetSecurity"),
        .package(path: "../FleetPersistence")
    ],
    targets: [
        .target(name: "FleetUI", dependencies: [
            "FleetCore",
            // FleetSecurity and FleetPersistence are declared now to pin the
            // intended dependency direction; M0 does not yet consume them.
            //
            // FleetNetworking is INTENTIONALLY NOT a dependency: SwiftUI must
            // never depend on JSON-RPC / WebSocket plumbing (M0 hard scope
            // guard). The transport seam (`HermesTransport`) lives in FleetCore
            // and is wired by the composition root only.
            "FleetSecurity",
            "FleetPersistence"
        ])
    ]
)
