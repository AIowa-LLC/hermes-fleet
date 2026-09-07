// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FleetCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v14) // host-side `swift test` convenience only; the product targets iOS
    ],
    products: [
        .library(name: "FleetCore", targets: ["FleetCore"])
    ],
    targets: [
        .target(name: "FleetCore"),
        .testTarget(name: "FleetCoreTests", dependencies: ["FleetCore"])
    ]
)
