// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DuckHuntCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "DuckHuntCore", targets: ["DuckHuntCore"]),
    ],
    targets: [
        .target(name: "DuckHuntCore"),
        .testTarget(
            name: "DuckHuntCoreTests",
            dependencies: ["DuckHuntCore"]
        ),
    ]
)
