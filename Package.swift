// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "ztat",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ztat", targets: ["ZtatApp"])
    ],
    dependencies: [
        .package(path: "Packages/ZtatCore"),
        .package(path: "Packages/ZtatPowerGuard"),
        .package(path: "Packages/ZtatStats"),
        .package(path: "Packages/ZtatStatusTrio"),
        .package(path: "Packages/ZtatIsland"),
        .package(path: "Packages/ZtatCleaner"),
        .package(path: "Packages/ZtatVorssaint")
    ],
    targets: [
        .executableTarget(
            name: "ZtatApp",
            dependencies: [
                .product(name: "ZtatCore", package: "ZtatCore"),
                .product(name: "ZtatPowerGuard", package: "ZtatPowerGuard"),
                .product(name: "ZtatStatsHost", package: "ZtatStats"),
                .product(name: "ZtatStatusTrio", package: "ZtatStatusTrio"),
                .product(name: "ZtatIsland", package: "ZtatIsland"),
                .product(name: "ZtatCleaner", package: "ZtatCleaner"),
                .product(name: "ZtatVorssaint", package: "ZtatVorssaint")
            ],
            path: "Sources/ZtatApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "ZtatTests",
            dependencies: [
                .product(name: "ZtatCore", package: "ZtatCore"),
                .product(name: "ZtatPowerGuard", package: "ZtatPowerGuard"),
                .product(name: "ZtatStatsHost", package: "ZtatStats"),
                .product(name: "StatsKit", package: "ZtatStats"),
                .product(name: "ZtatStatusTrio", package: "ZtatStatusTrio"),
                .product(name: "ZtatIsland", package: "ZtatIsland"),
                .product(name: "ZtatCleaner", package: "ZtatCleaner"),
                .product(name: "ZtatVorssaint", package: "ZtatVorssaint")
            ],
            path: "Tests/ZtatTests"
        )
    ]
)
