// swift-tools-version: 6.0
// ZTAT-PATCH: Standalone SwiftPM manifest for ZtatStatusTrio static host library without Sparkle or PowerHelper daemon.

import PackageDescription

let package = Package(
    name: "ZtatStatusTrio",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZtatStatusTrio", targets: ["StatusTrioCore"]),
        .library(name: "AirPodsAudioContext", type: .dynamic, targets: ["AirPodsAudioContext"]),
        .executable(name: "StatusTrioAirPodsHelper", targets: ["StatusTrioAirPodsHelper"])
    ],
    dependencies: [
        .package(path: "../ZtatCore")
    ],
    targets: [
        .target(
            name: "DDCPrivateAPI",
            path: "Sources/DDCPrivateAPI",
            exclude: ["LICENSE-AppleSiliconDDC.txt"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "PowerUIPrivateAPI",
            path: "Sources/PowerUIPrivateAPI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "PowerHelperProtocol",
            path: "Sources/PowerHelperProtocol"
        ),
        .target(
            name: "AirPodsAudioContext",
            path: "Sources/AirPodsAudioContext",
            exclude: ["LICENSE"],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "StatusTrioAirPodsHelper",
            path: "Sources/StatusTrioAirPodsHelper",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "StatusTrioCore",
            dependencies: [
                .product(name: "ZtatCore", package: "ZtatCore"),
                "DDCPrivateAPI",
                "PowerUIPrivateAPI",
                "PowerHelperProtocol"
            ],
            path: "Sources/StatusTrioCore",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreDisplay"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("IOReport")
            ]
        )
    ]
)
