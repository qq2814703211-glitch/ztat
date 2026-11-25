// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Pure SwiftPM package manifest porting exelban/stats (9 hardware modules, zero Xcode/LevelDB/Sparkle/WidgetKit)

import PackageDescription

let swift5Settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5)
]

let commonModuleDeps: [Target.Dependency] = [
    "StatsKit",
    "CStatsHardware",
    .product(name: "ZtatCore", package: "ZtatCore")
]

let package = Package(
    name: "ZtatStats",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZtatStatsHost", targets: ["ZtatStatsHost"]),
        .library(name: "StatsKit", targets: ["StatsKit"])
    ],
    dependencies: [
        .package(path: "../ZtatCore")
    ],
    targets: [
        .target(
            name: "CStatsHardware",
            path: "Sources/CStatsHardware",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
                .linkedLibrary("IOReport")
            ]
        ),
        .target(
            name: "StatsKit",
            dependencies: [
                "CStatsHardware",
                .product(name: "ZtatCore", package: "ZtatCore")
            ],
            path: "Sources/StatsKit",
            resources: [
                .process("Resources")
            ],
            swiftSettings: swift5Settings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .target(
            name: "StatsCPU",
            dependencies: commonModuleDeps,
            path: "Sources/Modules/CPU",
            resources: [.process("config.plist")],
            swiftSettings: swift5Settings
        ),
        .target(
            name: "StatsGPU",
            dependencies: commonModuleDeps,
            path: "Sources/Modules/GPU",
            resources: [.process("config.plist")],
            swiftSettings: swift5Settings
        ),
        .target(
            name: "StatsRAM",
            dependencies: commonModuleDeps,
            path: "Sources/Modules/RAM",
            resources: [.process("config.plist")],
            swiftSettings: swift5Settings
        ),
        .target(
            name: "StatsDisk",
            dependencies: commonModuleDeps,
            path: "Sources/Modules/Disk",
            resources: [.process("config.plist")],
            swiftSettings: swift5Settings,
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "StatsNet",
            dependencies: commonModuleDeps,
            path: "Sources/Modules/Net",
            resources: [.process("config.plist")],
            swiftSettings: swift5Settings,
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .target(
            name: "StatsBattery",
            dependencies: commonModuleDeps,
            path: "Sources/Modules/Battery",
            resources: [.process("config.plist")],
            swiftSettings: swift5Settings,
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .target(
            name: "StatsSensors",
            dependencies: commonModuleDeps,
            path: "Sources/Modules/Sensors",
            resources: [.process("config.plist")],
            swiftSettings: swift5Settings
        ),
        .target(
            name: "StatsBluetooth",
            dependencies: commonModuleDeps,
            path: "Sources/Modules/Bluetooth",
            resources: [.process("config.plist")],
            swiftSettings: swift5Settings,
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth")
            ]
        ),
        .target(
            name: "StatsClock",
            dependencies: commonModuleDeps,
            path: "Sources/Modules/Clock",
            resources: [.process("config.plist")],
            swiftSettings: swift5Settings
        ),
        .target(
            name: "ZtatStatsHost",
            dependencies: [
                .product(name: "ZtatCore", package: "ZtatCore"),
                "StatsKit",
                "StatsCPU",
                "StatsGPU",
                "StatsRAM",
                "StatsDisk",
                "StatsNet",
                "StatsBattery",
                "StatsSensors",
                "StatsBluetooth",
                "StatsClock"
            ],
            path: "Sources/ZtatStatsHost",
            swiftSettings: swift5Settings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Combine"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
