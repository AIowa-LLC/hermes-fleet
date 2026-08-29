// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FleetNetworking",
    platforms: [
        .iOS(.v17),
        .macOS(.v14) // host-side build convenience only; the product targets iOS
    ],
    products: [
        .library(name: "FleetNetworking", targets: ["FleetNetworking"])
    ],
    dependencies: [
        .package(path: "../FleetCore")
    ],
    targets: [
        .target(name: "FleetNetworking", dependencies: ["FleetCore"]),
        .testTarget(
            name: "FleetNetworkingTests",
            dependencies: ["FleetNetworking", "FleetCore"]
        )
    ]
)
