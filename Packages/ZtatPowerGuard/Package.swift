// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "ZtatPowerGuard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZtatPowerGuard", targets: ["ZtatPowerGuard"]),
        .executable(name: "ztat-hold", targets: ["ZtatPowerGuardCLI"])
    ],
    dependencies: [
        .package(path: "../ZtatCore")
    ],
    targets: [
        .target(
            name: "ZtatPowerGuard",
            dependencies: [
                .product(name: "ZtatCore", package: "ZtatCore")
            ],
            path: "Sources/ZtatPowerGuard",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "ZtatPowerGuardCLI",
            dependencies: [
                "ZtatPowerGuard",
                .product(name: "ZtatCore", package: "ZtatCore")
            ],
            path: "Sources/ZtatPowerGuardCLI"
        )
    ]
)
