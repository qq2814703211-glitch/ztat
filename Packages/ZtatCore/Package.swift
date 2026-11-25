// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "ZtatCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZtatCore", targets: ["ZtatCore"])
    ],
    targets: [
        .target(
            name: "ZtatCore",
            path: "Sources/ZtatCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation")
            ]
        )
    ]
)
