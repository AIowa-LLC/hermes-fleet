// swift-tools-version: 6.2
import PackageDescription

// Shared, dependency-free wire protocol and safety policy between the iPhone
// app and its Apple Watch companion. It deliberately imports neither
// FleetNetworking nor FleetSecurity: the Watch binary must never link code
// that can hold gateway credentials.
let package = Package(
    name: "FleetWatchKit",
    platforms: [
        .iOS(.v26),
        .watchOS(.v26),
        .macOS(.v14) // host-side `swift test` convenience only
    ],
    products: [
        .library(name: "FleetWatchKit", targets: ["FleetWatchKit"])
    ],
    targets: [
        .target(name: "FleetWatchKit"),
        .testTarget(name: "FleetWatchKitTests", dependencies: ["FleetWatchKit"])
    ]
)
