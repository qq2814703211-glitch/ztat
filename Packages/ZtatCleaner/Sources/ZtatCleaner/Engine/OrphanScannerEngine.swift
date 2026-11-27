// SPDX-License-Identifier: GPL-3.0-or-later
// Reverse Orphaned / Zombie Files scanner across 22 macOS Library paths
// with strong protection against Apple system tokens, active installed apps,
// UUID container metadata, and source repositories.

import Foundation
import ZtatCore

public final class OrphanScannerEngine: @unchecked Sendable {
    public static let shared = OrphanScannerEngine()

    private init() {}

    /// Protected macOS, Apple, runtime, browser, telemetry, and shared-framework tokens
    /// that must never be flagged as orphaned leftovers.
    private static let protectedTokens: [String] = [
        "apple", "icloud", "cloudkit", "clouddocs", "dock", "finder", "safari", "facetime",
        "messages", "mail", "photos", "notes", "reminders", "calendar", "contacts", "maps",
        "music", "podcasts", "tv", "books", "news", "weather", "stocks", "home", "wallet",
        "passkit", "siri", "spotlight", "webkit", "cfnetwork", "nsurlsession", "security",
        "keychain", "tcc", "systempreferences", "systemsettings", "coreaudio", "coredata",
        "coremedia", "coreimage", "coreml", "corelocation", "coresimulator", "coreduet",
        "bird", "biome", "duet", "knowledge", "trial", "familycircled", "screentime",
        "sharing", "bluetooth", "wifi", "airport", "networkextension", "vpn", "controlcenter",
        "notificationcenter", "windowserver", "loginwindow", "universalaccess", "accessibility",
        "speech", "dictation", "inputmethod", "keyboard", "font", "colorsync", "print",
        "cups", "crashreporter", "diagnosticreports", "spindump", "sysdiagnose", "osanalytics",
        "timemachine", "backupd", "mds", "mdworker", "launchservices", "sharedfilelist",
        "containermanager", "appstore", "commerce", "storeagent", "softwareupdate", "mobileasset",
        "xpc", "launchd", "cron", "periodic", "sandbox", "amfi", "gatekeeper", "xprotect",
        "mrt", "endpointsecurity", "fileprovider", "quicklook", "thumbnail", "iconservices",
        "ztat", "vorssaint", "statustrio", "powerguard", "atoll",
        "homebrew", "brew", "sparkle", "sentry", "crashlytics", "segment", "amplitude",
        "rollbar", "firebase", "google", "chromium", "microsoft", "mozilla", "adobe",
        "jetbrains", "python", "swiftpm", "swift", "clang", "llvm", "git", "ssh", "gnupg",
        "node", "npm", "pnpm", "yarn", "cargo", "rustup", "go", "gradle", "maven", "docker",
        "orbstack", "cef", "electron", "rosetta", "xcode", "developer", "instruments"
    ]

    public static func scannedDirectories(home: String = NSHomeDirectory()) -> [URL] {
        let userLib = URL(fileURLWithPath: home).appendingPathComponent("Library")
        let sysLib = URL(fileURLWithPath: "/Library")
        return [
            userLib.appendingPathComponent("Application Scripts"),
            userLib.appendingPathComponent("Application Support"),
            userLib.appendingPathComponent("Application Support/Caches"),
            userLib.appendingPathComponent("Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"),
            userLib.appendingPathComponent("Containers"),
            userLib.appendingPathComponent("Caches"),
            userLib.appendingPathComponent("HTTPStorages"),
            userLib.appendingPathComponent("Internet Plug-Ins"),
            userLib.appendingPathComponent("LaunchAgents"),
            userLib.appendingPathComponent("Logs"),
            userLib.appendingPathComponent("Preferences"),
            userLib.appendingPathComponent("PreferencePanes"),
            userLib.appendingPathComponent("Preferences/ByHost"),
            userLib.appendingPathComponent("Saved Application State"),
            userLib.appendingPathComponent("WebKit"),
            URL(fileURLWithPath: "/Users/Shared/Library/Application Support"),
            sysLib.appendingPathComponent("Application Support"),
            sysLib.appendingPathComponent("Application Support/CrashReporter"),
            sysLib.appendingPathComponent("Internet Plug-Ins"),
            sysLib.appendingPathComponent("LaunchAgents"),
            sysLib.appendingPathComponent("LaunchDaemons"),
            sysLib.appendingPathComponent("PrivilegedHelperTools")
        ]
    }

    public func scanOrphans(
        installedApps: [InstalledAppEntry],
        exclusions: [String],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [OrphanedFileItem] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let home = (NSHomeDirectory() as NSString).standardizingPath
            let dirs = Self.scannedDirectories(home: home)

            // Build fast lookup sets of all active installed app identifiers (length >= 5)
            var activeBundleIDs = Set<String>()
            var activeNormalizedTokens = Set<String>()
            var activeVendors = Set<String>()

            for app in installedApps {
                let bid = app.bundleIdentifier.lowercased()
                if !bid.isEmpty {
                    activeBundleIDs.insert(bid)
                    let normBid = CleanerFormatters.normalizedToken(bid)
                    if normBid.count >= 5 { activeNormalizedTokens.insert(normBid) }
                    let parts = bid.split(separator: ".").map(String.init)
                    if parts.count >= 3 {
                        let vendor = CleanerFormatters.normalizedToken(parts[1])
                        if vendor.count >= 4 { activeVendors.insert(vendor) }
                    }
                    if let last = parts.last {
                        let normLast = CleanerFormatters.normalizedToken(last)
                        if normLast.count >= 5 { activeNormalizedTokens.insert(normLast) }
                    }
                }
                let normName = CleanerFormatters.normalizedToken(app.name)
                if normName.count >= 5 { activeNormalizedTokens.insert(normName) }
                let normStem = CleanerFormatters.normalizedToken(app.url.deletingPathExtension().lastPathComponent)
                if normStem.count >= 5 { activeNormalizedTokens.insert(normStem) }
                for ent in app.entitlementGroups {
                    let normEnt = CleanerFormatters.normalizedToken(ent)
                    if normEnt.count >= 5 { activeNormalizedTokens.insert(normEnt) }
                }
            }

            var results: [OrphanedFileItem] = []
            var seen = Set<String>()

            for (idx, dir) in dirs.enumerated() {
                if Task.isCancelled { break }
                onProgress?(idx + 1, dirs.count)
                guard fm.fileExists(atPath: dir.path) else { continue }
                guard let children = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                let isContainersDir = dir.lastPathComponent == "Containers"

                for child in children {
                    if Task.isCancelled { break }
                    let clean = child.standardizedFileURL
                    let path = clean.path
                    guard seen.insert(path).inserted else { continue }
                    let vals = try? clean.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if vals?.isSymbolicLink == true { continue }

                    let name = clean.lastPathComponent
                    if name.hasPrefix(".") || Self.isDashlessHexUUID(name) { continue }
                    if self.matchesUserExclusion(path: path, exclusions: exclusions) { continue }
                    if SafePathGuard.rejectionReason(for: clean) != nil { continue }

                    // Container UUID metadata check
                    var ownerHint = name
                    if isContainersDir, let metaID = LeftoverScannerEngine.readContainerMetadataIdentifier(at: clean) {
                        ownerHint = metaID
                        if self.isProtectedOrInstalled(rawIdentifier: metaID, activeBundleIDs: activeBundleIDs, activeTokens: activeNormalizedTokens, activeVendors: activeVendors) {
                            continue
                        }
                    }

                    if self.isProtectedOrInstalled(rawIdentifier: name, activeBundleIDs: activeBundleIDs, activeTokens: activeNormalizedTokens, activeVendors: activeVendors) {
                        continue
                    }

                    // Only flag items that look like app-owned artifacts (reverse-DNS bundle ID, .plist, .savedState, .sfl*, or non-empty directory)
                    guard self.looksLikeAppArtifact(url: clean, isDirectory: vals?.isDirectory == true, isContainersDir: isContainersDir) else {
                        continue
                    }

                    let size = SafeDeletionEngine.logicalSize(of: clean)
                    let cat = LeftoverCategory.classify(url: clean)
                    results.append(OrphanedFileItem(
                        id: path,
                        url: clean,
                        category: cat,
                        size: size,
                        detectedOwnerHint: ownerHint,
                        isSelected: false // Safety first: orphans always start UNCHECKED so user reviews before trashing
                    ))
                }
            }

            return results.sorted { $0.size > $1.size }
        }.value
    }

    private func isProtectedOrInstalled(
        rawIdentifier: String,
        activeBundleIDs: Set<String>,
        activeTokens: Set<String>,
        activeVendors: Set<String>
    ) -> Bool {
        let lower = rawIdentifier.lowercased()
        if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.") || lower.hasPrefix("dev.ztat.") {
            return true
        }
        let norm = CleanerFormatters.normalizedToken(rawIdentifier)
        if norm.count < 4 { return true }

        for token in Self.protectedTokens {
            if norm.contains(token) || lower.contains(token) {
                return true
            }
        }

        // Exact or family match against any currently installed app's bundle ID
        for bid in activeBundleIDs {
            if lower == bid || lower.hasPrefix(bid + ".") || lower.contains(bid) {
                return true
            }
        }
        for tok in activeTokens {
            if norm == tok || (tok.count >= 5 && norm.contains(tok)) || (norm.count >= 5 && tok.contains(norm)) {
                return true
            }
        }
        for vendor in activeVendors where norm == vendor || lower.hasPrefix("com.\(vendor).") || lower.hasPrefix("org.\(vendor).") || lower.hasPrefix("io.\(vendor).") {
            return true
        }
        return false
    }

    private func looksLikeAppArtifact(url: URL, isDirectory: Bool, isContainersDir: Bool) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        if isContainersDir { return true }
        if ["plist", "savedstate", "sfl2", "sfl3", "sfl4", "plugin", "prefpane", "log"].contains(ext) {
            return true
        }
        // Reverse-DNS pattern (e.g. com.foo.bar)
        let dotParts = name.split(separator: ".")
        if dotParts.count >= 3, let first = dotParts.first, ["com", "org", "net", "io", "app", "dev", "me", "co", "ai", "cn", "jp", "de", "uk"].contains(first.lowercased()) {
            return true
        }
        return isDirectory
    }

    private func matchesUserExclusion(path: String, exclusions: [String]) -> Bool {
        let lower = path.lowercased()
        for ex in exclusions {
            let trimmed = ex.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            if path == expanded || path.hasPrefix(expanded + "/") || lower.contains(trimmed.lowercased()) {
                return true
            }
        }
        return false
    }

    private static func isDashlessHexUUID(_ name: String) -> Bool {
        guard name.count == 32 else { return false }
        return name.unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0)
        }
    }
}
