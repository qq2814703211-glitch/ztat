// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: SwiftPM library package manifest wrapping VorssaintToolbox + NowPlayingAdapter for ztat.

import PackageDescription

let package = Package(
    name: "ZtatVorssaint",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZtatVorssaint", targets: ["VorssaintToolbox"]),
        .library(name: "ZtatNowPlayingAdapter", type: .dynamic, targets: ["NowPlayingAdapter"])
    ],
    dependencies: [
        .package(path: "../ZtatCore")
    ],
    targets: [
        .systemLibrary(
            name: "CoreAudioTapCompat",
            path: "Sources/CoreAudioTapCompat"
        ),
        .systemLibrary(
            name: "HIDEventSystem",
            path: "Sources/HIDEventSystem"
        ),
        .systemLibrary(
            name: "VMStatisticsCompat",
            path: "Sources/VMStatisticsCompat"
        ),
        .target(
            name: "RecorderGIFCodec",
            path: "Sources/RecorderGIFCodec",
            sources: ["RecorderGIFCodec.c", "vendor/cgif/cgif_raw.c"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "NowPlayingAdapter",
            path: "Sources/NowPlayingAdapter",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "VorssaintToolbox",
            dependencies: [
                .product(name: "ZtatCore", package: "ZtatCore"),
                "VMStatisticsCompat",
                "HIDEventSystem",
                "CoreAudioTapCompat",
                "RecorderGIFCodec"
            ],
            path: "Sources/VorssaintToolbox",
            resources: [
                .copy("Resources/now-playing.pl"),
                .copy("Resources/agent-prices.json")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
