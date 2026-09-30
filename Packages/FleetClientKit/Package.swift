// swift-tools-version: 6.2
import PackageDescription

// FleetClientKit — the extension-safe client layer (F3).
//
// Extensions (Notification Service Extension, widgets, Live Activity, controls)
// run in separate, memory-limited processes that cannot link HermesFleetApp,
// AppEnvironment, FleetUI, or FleetNetworking's WebSocket stack. This package is
// the ONLY Fleet client code they may link besides FleetCore and FleetSecurity.
//
// Dependency rule (enforced by scripts/extension_boundary_guard.py and
// ModuleBoundaryTests): FleetClientKit depends on FleetCore and FleetSecurity
// only, imports nothing but Foundation/Security/OSLog/CryptoKit plus those two,
// and never imports FleetNetworking, FleetUI, FleetPersistence, SwiftUI, or
// UIKit. No SwiftData, no long-lived sockets.
let package = Package(
    name: "FleetClientKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v14) // host-side `swift test` convenience only; the product targets iOS
    ],
    products: [
        .library(name: "FleetClientKit", targets: ["FleetClientKit"])
    ],
    dependencies: [
        .package(path: "../FleetCore"),
        .package(path: "../FleetSecurity")
    ],
    targets: [
        .target(
            name: "FleetClientKit",
            dependencies: ["FleetCore", "FleetSecurity"]
        ),
        .testTarget(
            name: "FleetClientKitTests",
            dependencies: ["FleetClientKit", "FleetCore", "FleetSecurity"]
        )
    ]
)
