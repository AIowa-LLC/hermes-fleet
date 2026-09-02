// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FleetPersistence",
    platforms: [
        .iOS(.v26),
        .macOS(.v14) // host-side build convenience only; the product targets iOS
    ],
    products: [
        .library(name: "FleetPersistence", targets: ["FleetPersistence"])
    ],
    dependencies: [
        .package(path: "../FleetCore")
    ],
    targets: [
        .target(name: "FleetPersistence", dependencies: ["FleetCore"]),
        .testTarget(
            name: "FleetPersistenceTests",
            dependencies: ["FleetPersistence", "FleetCore"]
        )
    ]
)
