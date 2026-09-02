// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FleetSecurity",
    platforms: [
        .iOS(.v26),
        .macOS(.v14) // host-side build convenience only; the product targets iOS
    ],
    products: [
        .library(name: "FleetSecurity", targets: ["FleetSecurity"])
    ],
    dependencies: [
        .package(path: "../FleetCore")
    ],
    targets: [
        .target(name: "FleetSecurity", dependencies: ["FleetCore"]),
        .testTarget(
            name: "FleetSecurityTests",
            dependencies: ["FleetSecurity", "FleetCore"]
        )
    ]
)
