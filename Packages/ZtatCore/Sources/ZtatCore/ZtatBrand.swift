// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

public enum ZtatBrand {
    public static let appName = "ztat"
    public static let devAppName = "ztat (Dev)"
    public static let bundleIdentifier = "dev.ztat.app"
    public static let devBundleIdentifier = "dev.ztat.app.dev"
    public static let statsDefaultsSuite = "dev.ztat.app.stats"
    public static let powerGuardDefaultsPrefix = "ztat.powerGuard."
    public static let version = "1.0.0"
    public static let buildNumber = "1"
    public static let hubPanelWidth: CGFloat = 356

    public static var activeBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? bundleIdentifier
    }

    public static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var statsCacheDirectory: URL {
        let dir = appSupportDirectory.appendingPathComponent("stats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

public enum ZtatLog {
    public static let app = Logger(subsystem: ZtatBrand.bundleIdentifier, category: "App")
    public static let statusTrio = Logger(subsystem: ZtatBrand.bundleIdentifier, category: "StatusTrio")
    public static let stats = Logger(subsystem: ZtatBrand.bundleIdentifier, category: "Stats")
    public static let powerGuard = Logger(subsystem: ZtatBrand.bundleIdentifier, category: "PowerGuard")
    public static let vorssaint = Logger(subsystem: ZtatBrand.bundleIdentifier, category: "Vorssaint")
    public static let perf = Logger(subsystem: ZtatBrand.bundleIdentifier, category: "Performance")
}

public enum ZtatL10n {
    public static var isChinese: Bool {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("zh")
    }

    @inline(__always)
    public static func tr(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }
}
