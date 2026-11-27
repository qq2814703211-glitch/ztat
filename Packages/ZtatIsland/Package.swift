// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Pure SwiftPM package manifest for ZtatIsland (native Atoll Dynamic Island engine, Apple CLT compatible).

import PackageDescription

let package = Package(
    name: "ZtatIsland",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZtatIsland", targets: ["ZtatIsland"])
    ],
    dependencies: [
        .package(path: "../ZtatCore"),
        .package(url: "https://github.com/sindresorhus/Defaults", exact: "9.0.3"),
        // Pin SwiftTerm 1.10.0 to avoid 1.12+ Metal shader resources (requires Xcode xcrun metal)
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.10.0"),
        // Build Lottie from source to avoid precompiled xcframework Swift interface mismatch under CLT
        .package(url: "https://github.com/airbnb/lottie-ios", exact: "4.5.2"),
        .package(url: "https://github.com/Ebullioscopic/AtollExtensionKit", revision: "e2d30afedbbcc259bec7eeb1bea0757e52f4ca01")
    ],
    targets: [
        // ZTAT-PATCH: Vendored KeyboardShortcuts 2.3.0 (MIT) with #Preview guarded for pure Apple CLT builds.
        .target(
            name: "KeyboardShortcuts",
            path: "Sources/KeyboardShortcuts",
            exclude: ["LICENSE"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "CAudioBridge",
            path: "Sources/CAudioBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-fobjc-arc"])
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation")
            ]
        ),
        .target(
            name: "ZtatIsland",
            dependencies: [
                .product(name: "ZtatCore", package: "ZtatCore"),
                "CAudioBridge",
                "KeyboardShortcuts",
                .product(name: "Defaults", package: "Defaults"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Lottie", package: "lottie-ios"),
                .product(name: "AtollExtensionKit", package: "AtollExtensionKit")
            ],
            path: "Sources/ZtatIsland",
            resources: [
                .copy("Resources/Images"),
                .copy("Resources/Audio"),
                .copy("Resources/Lottie"),
                .copy("Resources/pricing.json"),
                .copy("Resources/mediaremote-adapter.pl"),
                .process("Resources/Localizations")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Cocoa"),
                .linkedFramework("Combine"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("IOKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("MusicKit"),
                .linkedFramework("Network"),
                .linkedFramework("OSLog"),
                .linkedFramework("PDFKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("QuickLook"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("TipKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Vision"),
                .linkedFramework("WebKit"),
                .linkedLibrary("sqlite3")
            ]
        )
    ],
    cxxLanguageStandard: .cxx20
)
