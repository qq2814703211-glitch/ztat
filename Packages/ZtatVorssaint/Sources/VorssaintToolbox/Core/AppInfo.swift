// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import ZtatCore // ZTAT-PATCH: Rebrand visible app identity to ztat per upstream TRADEMARKS.md.

/// Static identity of the app, shared by UI, notifications and tooling.
enum AppInfo {
    static let name = ZtatBrand.appName
    static let copyright = "© 2026 ztat (GPL-3.0-or-later)"
    static let websiteURL = URL(string: "https://github.com/dearglory/ztat")!
    static let repositoryURL = URL(string: "https://github.com/dearglory/ztat")!
    static let coffeeURL = URL(string: "https://github.com/dearglory/ztat")!
    static let discordURL = URL(string: "https://github.com/dearglory/ztat")!
    static let socialURL = URL(string: "https://github.com/dearglory/ztat")!

    /// The bundle version.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ZtatBrand.version
    }

    /// True for the local "Vorssaint (Developer)" build (bundle id ends in `.dev`).
    /// It is never published and never auto-updates; all work is tested here first.
    static var isDeveloperBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
    }

    /// True when the current version is a pre-release (e.g. 3.3.4-beta.1 or 3.3.4-rc.1).
    static var isBeta: Bool {
        if isDeveloperBuild && UserDefaults.standard.bool(forKey: DefaultsKey.simulateBetaUI) {
            return true
        }
        let v = version.lowercased()
        return v.contains("-beta") || v.contains("-rc") || v.contains("-alpha")
    }

    /// The git commit a Developer build was compiled from, e.g. "ed2ebba · 2026-06-15 21:30"
    /// (or with a "-dirty" suffix on the SHA for uncommitted changes). build.sh stamps
    /// this into the Developer bundle only, so you can confirm at a glance that the
    /// running dev app matches the source you are about to change. nil in the official app.
    static var buildCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "ZtatBuildCommit") as? String
    }
}
