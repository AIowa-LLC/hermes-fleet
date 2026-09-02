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
        ], resources: [
            // V1 (Nous direction): Courier Prime under the SIL Open Font
            // License (OFL.txt alongside) — the mono display typeface for
            // titles / stats / IDs. SF Mono is the runtime fallback when the
            // custom face is unavailable.
            .process("Resources")
        ])
    ]
)
