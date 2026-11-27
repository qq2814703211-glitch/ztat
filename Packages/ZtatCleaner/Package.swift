// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "ZtatCleaner",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZtatCleaner", targets: ["ZtatCleaner"])
    ],
    dependencies: [
        .package(path: "../ZtatCore")
    ],
    targets: [
        .target(
            name: "ZtatCleaner",
            dependencies: [
                .product(name: "ZtatCore", package: "ZtatCore")
            ],
            path: "Sources/ZtatCleaner",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Security"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
