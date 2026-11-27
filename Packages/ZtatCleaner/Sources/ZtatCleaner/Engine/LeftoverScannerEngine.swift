// SPDX-License-Identifier: GPL-3.0-or-later
// Deep macOS leftover file discovery engine for app uninstallation & app reset.
// Supports 3 sensitivity tiers (Strict / Enhanced / Deep), 13 categories,
// UUID container metadata resolution, safe vendor promotion, app disambiguation rules,
// user-linked orphans, path export, ditto bundling, and optional Homebrew --zap.

import CoreServices
import Foundation
import ZtatCore

public final class LeftoverScannerEngine: @unchecked Sendable {
    public static let shared = LeftoverScannerEngine()

    private init() {}

    /// High-risk macOS / user-data subdirectories inside ~/Library or /Library never traversed blindly.
    static let skippedLibrarySubdirectories: Set<String> = [
        "accounts", "addressbook", "application support", "assistants", "audio",
        "autosave information", "biome", "calendars", "callhistorydb", "callhistorytransactions",
        "cloudstorage", "colors", "colorpickers", "colorsync", "compositions", "contacts",
        "containers", "cookies", "coreservices", "coredata", "daemon containers",
        "dictionaries", "diskimages", "dographics", "facetime", "favorites", "finance",
        "fontcollections", "fonts", "frameworks", "frontboard", "gamekit", "group containers",
        "health", "homekit", "httpstorages", "icdd", "icloud", "identityservices",
        "input methods", "instruments", "intents", "internet plug-ins", "keyboard",
        "keyboard layouts", "keyboardservices", "keychains", "languageModeling", "launchagents",
        "launchdaemons", "logs", "mail", "maps", "messages", "metadata", "mobile documents",
        "mobilesync", "passes", "personalizationportrait", "photos", "preferencepanes",
        "preferences", "printers", "privilegedhelpertools", "pubSub", "quicklook",
        "reminders", "safari", "saved application state", "screen savers", "scriptingadditions",
        "search", "security", "services", "sharing", "siri", "sounds", "spelling",
        "spotlight", "stagedframeworks", "statuskit", "suggestions", "syncedpreferences",
        "syncservices", "systemextensions", "trial", "voices", "webkit", "widgets", "xcode"
    ]

    /// Standard Library subdirectories where matching an item must NOT promote the parent directory.
    private static let standardLibraryContainers: Set<String> = [
        "application scripts", "application support", "caches", "containers", "cookies",
        "daemon containers", "extensions", "group containers", "httpstorages",
        "internet plug-ins", "launchagents", "launchdaemons", "logs", "preferencepanes",
        "preferences", "privilegedhelpertools", "saved application state", "services",
        "syncedpreferences", "webkit"
    ]

    private static let helperBundleSuffixes: Set<String> = [
        "helper", "agent", "daemon", "service", "xpc", "launcher", "updater",
        "installer", "uninstaller", "login", "extension", "plugin", "watchdog"
    ]

    /// Curated disambiguation rules preventing cross-app false positives.
    ///
    /// Rules are keyed by the *exact* bundle identifier: every release channel (Beta, Canary,
    /// Insiders, Developer Edition, …) has its own rule, so a variant can never inherit the stable
    /// app's force-included data folders, and `variantBundleIDs` makes sure the stable app never
    /// claims a sibling channel's identifier namespace even when that sibling is not installed.
    private struct DisambiguationRule {
        /// Lowercased bundle identifier this rule applies to (exact match only).
        let bundleID: String
        /// Extra normalized tokens owned by this app (whole-token equality only).
        let extraIncludeTokens: [String]
        /// Substrings that veto a match outright (conservative: only ever removes candidates).
        let excludeTokens: [String]
        /// Well-known data folders owned exclusively by this app / channel.
        let forceIncludePaths: [String]
        /// Lowercased bundle identifiers of sibling release channels of the same product.
        let variantBundleIDs: [String]
        /// `forceIncludePaths` are shared with the variants (e.g. Firefox profiles); they are only
        /// claimed while no variant is installed.
        let forceIncludeSharedWithVariants: Bool

        init(
            _ bundleID: String,
            extraIncludeTokens: [String] = [],
            excludeTokens: [String] = [],
            forceIncludePaths: [String] = [],
            variantBundleIDs: [String] = [],
            forceIncludeSharedWithVariants: Bool = false
        ) {
            self.bundleID = bundleID.lowercased()
            self.extraIncludeTokens = extraIncludeTokens
            self.excludeTokens = excludeTokens
            self.forceIncludePaths = forceIncludePaths
            self.variantBundleIDs = variantBundleIDs.map { $0.lowercased() }
            self.forceIncludeSharedWithVariants = forceIncludeSharedWithVariants
        }
    }

    private static let vscodeFamily = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.microsoft.VSCodeExploration"]
    private static let chromeFamily = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary", "com.google.chrome.for.testing"]
    private static let edgeFamily = ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary"]
    private static let braveFamily = ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"]
    private static let firefoxFamily = ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]

    private static func siblings(of bundleID: String, in family: [String]) -> [String] {
        family.filter { $0.lowercased() != bundleID.lowercased() }
    }

    private static let disambiguationRules: [DisambiguationRule] = {
        let chromeExcludes = ["iterm", "monochrome", "chromecast"]
        let edgeExcludes = ["vscode", "office", "knowledge"]
        let support = "~/Library/Application Support"
        return [
            // Visual Studio Code channels
            DisambiguationRule("com.microsoft.VSCode",
                               excludeTokens: ["insiders", "exploration"],
                               forceIncludePaths: ["\(support)/Code", "~/.vscode"],
                               variantBundleIDs: siblings(of: "com.microsoft.VSCode", in: vscodeFamily)),
            DisambiguationRule("com.microsoft.VSCodeInsiders",
                               extraIncludeTokens: ["codeinsiders"],
                               excludeTokens: ["exploration"],
                               forceIncludePaths: ["\(support)/Code - Insiders", "~/.vscode-insiders"],
                               variantBundleIDs: siblings(of: "com.microsoft.VSCodeInsiders", in: vscodeFamily)),
            DisambiguationRule("com.microsoft.VSCodeExploration",
                               excludeTokens: ["insiders"],
                               forceIncludePaths: ["\(support)/Code - Exploration", "~/.vscode-exploration"],
                               variantBundleIDs: siblings(of: "com.microsoft.VSCodeExploration", in: vscodeFamily)),
            // Arc
            DisambiguationRule("company.thebrowser.Browser",
                               extraIncludeTokens: ["thebrowser"],
                               excludeTokens: ["archive", "search", "arch"],
                               forceIncludePaths: ["\(support)/Arc"]),
            // Google Chrome channels
            DisambiguationRule("com.google.Chrome",
                               excludeTokens: chromeExcludes + ["chromebeta", "chromecanary", "chromefortesting"],
                               forceIncludePaths: ["\(support)/Google/Chrome"],
                               variantBundleIDs: siblings(of: "com.google.Chrome", in: chromeFamily)),
            DisambiguationRule("com.google.Chrome.beta",
                               excludeTokens: chromeExcludes,
                               forceIncludePaths: ["\(support)/Google/Chrome Beta"],
                               variantBundleIDs: siblings(of: "com.google.Chrome.beta", in: chromeFamily)),
            DisambiguationRule("com.google.Chrome.dev",
                               excludeTokens: chromeExcludes,
                               forceIncludePaths: ["\(support)/Google/Chrome Dev"],
                               variantBundleIDs: siblings(of: "com.google.Chrome.dev", in: chromeFamily)),
            DisambiguationRule("com.google.Chrome.canary",
                               excludeTokens: chromeExcludes,
                               forceIncludePaths: ["\(support)/Google/Chrome Canary"],
                               variantBundleIDs: siblings(of: "com.google.Chrome.canary", in: chromeFamily)),
            DisambiguationRule("com.google.chrome.for.testing",
                               excludeTokens: chromeExcludes,
                               forceIncludePaths: ["\(support)/Google/Chrome for Testing"],
                               variantBundleIDs: siblings(of: "com.google.chrome.for.testing", in: chromeFamily)),
            // Microsoft Edge channels
            DisambiguationRule("com.microsoft.edgemac",
                               excludeTokens: edgeExcludes + ["edgebeta", "edgedev", "edgecanary"],
                               forceIncludePaths: ["\(support)/Microsoft Edge"],
                               variantBundleIDs: siblings(of: "com.microsoft.edgemac", in: edgeFamily)),
            DisambiguationRule("com.microsoft.edgemac.Beta",
                               excludeTokens: edgeExcludes,
                               forceIncludePaths: ["\(support)/Microsoft Edge Beta"],
                               variantBundleIDs: siblings(of: "com.microsoft.edgemac.Beta", in: edgeFamily)),
            DisambiguationRule("com.microsoft.edgemac.Dev",
                               excludeTokens: edgeExcludes,
                               forceIncludePaths: ["\(support)/Microsoft Edge Dev"],
                               variantBundleIDs: siblings(of: "com.microsoft.edgemac.Dev", in: edgeFamily)),
            DisambiguationRule("com.microsoft.edgemac.Canary",
                               excludeTokens: edgeExcludes,
                               forceIncludePaths: ["\(support)/Microsoft Edge Canary"],
                               variantBundleIDs: siblings(of: "com.microsoft.edgemac.Canary", in: edgeFamily)),
            // Firefox channels share ~/Library/Application Support/Firefox (profiles.ini)
            DisambiguationRule("org.mozilla.firefox",
                               excludeTokens: ["thunderbird", "developeredition", "nightly"],
                               forceIncludePaths: ["\(support)/Firefox"],
                               variantBundleIDs: siblings(of: "org.mozilla.firefox", in: firefoxFamily),
                               forceIncludeSharedWithVariants: true),
            DisambiguationRule("org.mozilla.firefoxdeveloperedition",
                               excludeTokens: ["thunderbird"],
                               forceIncludePaths: ["\(support)/Firefox"],
                               variantBundleIDs: siblings(of: "org.mozilla.firefoxdeveloperedition", in: firefoxFamily),
                               forceIncludeSharedWithVariants: true),
            DisambiguationRule("org.mozilla.nightly",
                               excludeTokens: ["thunderbird"],
                               forceIncludePaths: ["\(support)/Firefox"],
                               variantBundleIDs: siblings(of: "org.mozilla.nightly", in: firefoxFamily),
                               forceIncludeSharedWithVariants: true),
            // Brave channels (BraveSoftware/ is a shared vendor folder: never claim it whole)
            DisambiguationRule("com.brave.Browser",
                               excludeTokens: ["browserbeta", "browsernightly"],
                               forceIncludePaths: ["\(support)/BraveSoftware/Brave-Browser"],
                               variantBundleIDs: siblings(of: "com.brave.Browser", in: braveFamily)),
            DisambiguationRule("com.brave.Browser.beta",
                               forceIncludePaths: ["\(support)/BraveSoftware/Brave-Browser-Beta"],
                               variantBundleIDs: siblings(of: "com.brave.Browser.beta", in: braveFamily)),
            DisambiguationRule("com.brave.Browser.nightly",
                               forceIncludePaths: ["\(support)/BraveSoftware/Brave-Browser-Nightly"],
                               variantBundleIDs: siblings(of: "com.brave.Browser.nightly", in: braveFamily)),
            // Others
            DisambiguationRule("com.logi.optionsplus",
                               extraIncludeTokens: ["logioptionsplus"],
                               excludeTokens: ["login", "logic", "logitechg"]),
            DisambiguationRule("com.apple.dt.Xcode",
                               excludeTokens: ["xcodes", "xcodecleaner"]),
            DisambiguationRule("com.todesktop.230313mzl4w4u92",
                               extraIncludeTokens: ["cursor"],
                               excludeTokens: ["cursors"],
                               forceIncludePaths: ["\(support)/Cursor", "~/.cursor"])
        ]
    }()

    /// Everything `matchToken` needs to decide ownership of a candidate name, including the
    /// identities of every *other* installed app so that the most specific owner always wins.
    private struct MatchContext {
        let profile: IdentityProfile
        let sensitivity: CleanerSearchSensitivity
        let rule: DisambiguationRule?
        /// Lowercased bundle IDs of other installed apps plus known sibling release channels.
        let competingBundleIDs: Set<String>
        /// Normalized names / bundle stems / executable names of other installed apps.
        let competingNames: Set<String>
        /// Word-token sequences of other installed apps' names (for whole-token prefix matching).
        let competingNameWords: [[String]]
        /// Another installed app is signed by the same Team ID.
        let teamIDShared: Bool
        /// Another installed app uses the same reverse-DNS vendor segment.
        let vendorShared: Bool
    }

    /// Scans all leftover files associated with `app` according to sensitivity, custom exclusions,
    /// linked orphans, and installed-app sibling awareness.
    public func scanLeftovers(
        for app: InstalledAppEntry,
        allInstalledApps: [InstalledAppEntry],
        sensitivity: CleanerSearchSensitivity,
        customExclusions: [String],
        linkedOrphanPaths: [String]
    ) async -> [LeftoverItem] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let home = (NSHomeDirectory() as NSString).standardizingPath
            let ownBundleID = app.bundleIdentifier.lowercased()
            let rule = ownBundleID.isEmpty ? nil : Self.disambiguationRules.first { $0.bundleID == ownBundleID }

            // Every OTHER installed app (other copies of the very same bundle ID share its identity).
            let otherApps = allInstalledApps.filter { other in
                other.id != app.id
                    && (ownBundleID.isEmpty || other.bundleIdentifier.lowercased() != ownBundleID)
            }
            let installedOtherBundleIDs = Set(otherApps.map { $0.bundleIdentifier.lowercased() }.filter { !$0.isEmpty })

            // App Group identifiers declared by any other installed app are shared (e.g. Office suite
            // `UBF8T346G9.Office`) and must never be claimed by this app.
            let sharedGroupIDs = Set(otherApps.flatMap(\.entitlementGroups).map { $0.lowercased() })
            let profile = self.buildIdentityProfile(for: app, sharedGroupIDs: sharedGroupIDs)

            // Build sibling tokens from OTHER installed apps so we never claim shared vendor folders
            let siblingVendorTokens = Set(
                otherApps.compactMap { other -> String? in
                    let parts = other.bundleIdentifier.lowercased().split(separator: ".")
                    return parts.count >= 3 ? CleanerFormatters.normalizedToken(String(parts[1])) : nil
                }
            )

            var competingBundleIDs = installedOtherBundleIDs.union(rule?.variantBundleIDs ?? [])
            competingBundleIDs.remove(ownBundleID)

            var competingNames = Set<String>()
            var competingNameWords: [[String]] = []
            for other in otherApps {
                let stem = other.url.deletingPathExtension().lastPathComponent
                for raw in [other.name, stem] + other.executableNames {
                    let norm = CleanerFormatters.normalizedToken(raw)
                    if norm.count >= 3 { competingNames.insert(norm) }
                }
                for raw in [other.name, stem] {
                    let words = Self.wordTokens(Self.versionStrippedName(raw))
                    if !words.isEmpty { competingNameWords.append(words) }
                }
            }

            let ownTeamID = profile.teamID
            let context = MatchContext(
                profile: profile,
                sensitivity: sensitivity,
                rule: rule,
                competingBundleIDs: competingBundleIDs,
                competingNames: competingNames,
                competingNameWords: competingNameWords,
                teamIDShared: !ownTeamID.isEmpty && otherApps.contains { ($0.teamIdentifier ?? "").lowercased() == ownTeamID },
                vendorShared: !profile.companyName.isEmpty && siblingVendorTokens.contains(profile.companyName)
            )

            var candidates: [String: (url: URL, reason: String, isLinked: Bool, isContainerUUID: Bool)] = [:]

            // 1. Always include the main `.app` bundle first (unchecked if already in Trash)
            candidates[app.url.standardizedFileURL.path] = (
                url: app.url.standardizedFileURL,
                reason: ZtatL10n.tr("应用程序本体", "Application Bundle"),
                isLinked: false,
                isContainerUUID: false
            )

            // 2. Steam game manifest & desktop shortcut if applicable
            if app.isSteamGame, let steamID = app.steamAppID {
                let manifest = URL(fileURLWithPath: home)
                    .appendingPathComponent("Library/Application Support/Steam/steamapps/appmanifest_\(steamID).acf")
                if fm.fileExists(atPath: manifest.path) {
                    candidates[manifest.path] = (manifest, "Steam Manifest", false, false)
                }
                let desktopLink = URL(fileURLWithPath: home)
                    .appendingPathComponent("Desktop/\(app.url.lastPathComponent)")
                if fm.fileExists(atPath: desktopLink.path) {
                    candidates[desktopLink.path] = (desktopLink, "Steam Shortcut", false, false)
                }
            }

            // 3. Narrow scan strictly for Web Apps to avoid false positives on generic site names
            let searchLocations = app.isWebApp
                ? self.webAppLocations(home: home)
                : self.standardSearchLocations(home: home)

            for loc in searchLocations {
                guard fm.fileExists(atPath: loc.url.path) else { continue }
                guard let entries = try? fm.contentsOfDirectory(
                    at: loc.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                ) else { continue }

                for entry in entries {
                    let clean = entry.standardizedFileURL
                    let path = clean.path
                    if self.isGloballySkipped(clean, home: home, exclusions: customExclusions, rule: rule) {
                        continue
                    }

                    // Special Container UUID metadata check (`~/Library/Containers/<UUID>/.com.apple.containermanagerd.metadata.plist`)
                    if loc.checkContainerMetadata {
                        if let metaID = Self.readContainerMetadataIdentifier(at: clean) {
                            if let reason = self.matchToken(metaID, context: context, allowNameMatch: false) {
                                candidates[path] = (clean, "\(reason) (Container Metadata)", false, true)
                                continue
                            }
                        }
                    }

                    // Check entry filename / stem
                    let fileName = clean.lastPathComponent
                    let stem = (try? clean.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                        ? fileName
                        : clean.deletingPathExtension().lastPathComponent

                    if let reason = self.matchToken(stem, context: context, allowNameMatch: loc.allowNameMatch)
                        ?? self.matchToken(fileName, context: context, allowNameMatch: loc.allowNameMatch) {
                        candidates[path] = (clean, reason, false, false)
                    }
                }
            }

            // 4. Depth-2 vendor subdirectory scan inside ~/Library/Application Support/* and /Library/* (safe promotion)
            if !app.isWebApp {
                self.scanVendorSubfolders(
                    in: [
                        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support"),
                        URL(fileURLWithPath: "/Library/Application Support"),
                        URL(fileURLWithPath: home).appendingPathComponent("Library"),
                        URL(fileURLWithPath: "/Library")
                    ],
                    context: context,
                    home: home,
                    exclusions: customExclusions,
                    rule: rule,
                    into: &candidates
                )
            }

            // 5. Security App Group Containers (exact OS lookup). Groups also declared by another
            //    installed app are shared suite storage and are never claimed.
            for groupID in app.entitlementGroups where !sharedGroupIDs.contains(groupID.lowercased()) {
                let groupDir = URL(fileURLWithPath: home)
                    .appendingPathComponent("Library/Group Containers/\(groupID)")
                    .standardizedFileURL
                guard fm.fileExists(atPath: groupDir.path),
                      !self.isGloballySkipped(groupDir, home: home, exclusions: customExclusions, rule: rule),
                      SafePathGuard.rejectionReason(for: groupDir) == nil else { continue }
                candidates[groupDir.path] = (groupDir, "App Group Entitlement", false, false)
            }

            // 6. Disambiguation force-include paths (e.g. VS Code -> ~/Library/Application Support/Code).
            //    Paths shared between release channels are only claimed while no sibling channel is installed.
            if let rule {
                let sharedWithInstalledVariant = rule.forceIncludeSharedWithVariants
                    && rule.variantBundleIDs.contains(where: installedOtherBundleIDs.contains)
                for rawPath in rule.forceIncludePaths where !sharedWithInstalledVariant {
                    let expanded = (rawPath as NSString).expandingTildeInPath
                    let url = URL(fileURLWithPath: expanded).standardizedFileURL
                    if fm.fileExists(atPath: url.path)
                        && !self.isGloballySkipped(url, home: home, exclusions: customExclusions, rule: rule)
                        && SafePathGuard.rejectionReason(for: url) == nil {
                        candidates[url.path] = (url, ZtatL10n.tr("已知应用目录", "Known App Directory"), false, false)
                    }
                }
            }

            // 7. User-linked orphan files
            for rawPath in linkedOrphanPaths {
                let url = URL(fileURLWithPath: rawPath).standardizedFileURL
                if fm.fileExists(atPath: url.path) {
                    candidates[url.path] = (url, ZtatL10n.tr("手动关联的残留", "Manually Linked Orphan"), true, false)
                }
            }

            // 8. Drop anything SafePathGuard would refuse to trash (e.g. `~/Library/Containers/com.apple.*`)
            //    so it is never listed or pre-selected, then deduplicate nested children
            //    (never collapse the main `.app` bundle out). Filtering before deduplication keeps
            //    allowed children whose rejected parent is dropped.
            let mainPath = app.url.standardizedFileURL.path
            candidates = candidates.filter { path, info in
                path == mainPath || SafePathGuard.rejectionReason(for: info.url) == nil
            }
            let sortedPaths = candidates.keys.sorted { $0.count < $1.count }
            var collapsedPaths: [String] = []
            for p in sortedPaths {
                if p == mainPath {
                    collapsedPaths.append(p)
                    continue
                }
                let covered = collapsedPaths.contains { parent in
                    parent != mainPath && (p == parent || p.hasPrefix(parent + "/"))
                }
                if !covered {
                    collapsedPaths.append(p)
                }
            }

            // 9. Compute sizes & build LeftoverItem array
            let groupContainersRoot = URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Group Containers").standardizedFileURL.path.lowercased() + "/"
            var results: [LeftoverItem] = []
            results.reserveCapacity(collapsedPaths.count)
            for p in collapsedPaths {
                guard let info = candidates[p] else { continue }
                let isMain = (p == mainPath)
                let cat = LeftoverCategory.classify(url: info.url, isMainApp: isMain)
                let size = isMain ? app.bundleSize : SafeDeletionEngine.logicalSize(of: info.url)
                let writable = fm.isWritableFile(atPath: info.url.path)
                // App Group containers are shared storage by design: only pre-select the ones
                // namespaced to this app's own bundle ID (e.g. `group.com.vendor.app`, `TEAMID.com.vendor.app`).
                let isGroupContainer = p.lowercased().hasPrefix(groupContainersRoot)
                let groupOwnedByApp = isGroupContainer
                    && Self.containsIdentifier(info.url.lastPathComponent.lowercased(), ownBundleID)
                let selectedByDefault: Bool
                if isMain {
                    selectedByDefault = !app.isAlreadyInTrash
                } else if isGroupContainer {
                    selectedByDefault = groupOwnedByApp
                } else {
                    selectedByDefault = true
                }
                results.append(LeftoverItem(
                    id: p,
                    url: info.url,
                    category: cat,
                    size: size,
                    matchReason: info.reason,
                    isLinkedOrphan: info.isLinked,
                    isContainerUUID: info.isContainerUUID,
                    isReadOnlyOrPrivileged: !writable,
                    isSelected: selectedByDefault
                ))
            }

            // Sort main `.app` first, then by category and descending size
            return results.sorted { lhs, rhs in
                if lhs.category == .appBundle && rhs.category != .appBundle { return true }
                if lhs.category != .appBundle && rhs.category == .appBundle { return false }
                if lhs.category.rawValue != rhs.category.rawValue {
                    return lhs.category.rawValue < rhs.category.rawValue
                }
                return lhs.size > rhs.size
            }
        }.value
    }

    // MARK: - Export Paths & Ditto Archive Bundle

    public func exportPathsText(for items: [LeftoverItem], appName: String) -> String {
        let header = "# \(appName) — Leftover Files (\(items.count) items)\n"
        let lines = items.map(\.displayPath).sorted()
        return header + lines.joined(separator: "\n") + "\n"
    }

    /// Creates a reversible `.zip` archive of selected files using macOS `/usr/bin/ditto`.
    public func bundleFilesArchive(urls: [URL], destinationZip: URL) async -> (Bool, String?) {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let staging = fm.temporaryDirectory.appendingPathComponent("ztat-bundle-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                for url in urls where fm.fileExists(atPath: url.path) {
                    let relPath = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
                    let dest = staging.appendingPathComponent(relPath)
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let copy = try CleanerProcessRunner.run("/usr/bin/ditto", [url.path, dest.path])
                    guard copy.succeeded else {
                        let err = copy.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                        return (false, err.isEmpty ? "ditto failed for \(url.path)" : err)
                    }
                }
                let zip = try CleanerProcessRunner.run(
                    "/usr/bin/ditto",
                    ["-c", "-k", "--sequesterRsrc", staging.path, destinationZip.path]
                )
                if zip.succeeded {
                    return (true, nil)
                }
                let err = zip.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                return (false, err.isEmpty ? "ditto exited with status \(zip.status)" : err)
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }

    /// Runs `brew uninstall --cask <token> --zap --force` when Homebrew cask cleanup is opted in.
    public func runHomebrewCaskZap(token: String) async -> (Bool, String) {
        await Task.detached(priority: .userInitiated) {
            let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            guard let brew = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return (false, "Homebrew binary not found")
            }
            // Cask tokens are [a-z0-9@._+-]; anything else (e.g. a leading "-") is refused.
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789@._+-")
            guard !token.isEmpty, !token.hasPrefix("-"),
                  token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                return (false, "Invalid Homebrew cask token: \(token)")
            }
            var env = ProcessInfo.processInfo.environment
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            do {
                let result = try CleanerProcessRunner.run(
                    brew,
                    ["uninstall", "--cask", "--zap", "--force", token],
                    environment: env
                )
                return (result.succeeded, result.combinedTrimmed)
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }

    // MARK: - Search Locations & Profile Matching

    private struct SearchLocation {
        let url: URL
        let allowNameMatch: Bool
        let checkContainerMetadata: Bool
    }

    private func webAppLocations(home: String) -> [SearchLocation] {
        let lib = URL(fileURLWithPath: home).appendingPathComponent("Library")
        return [
            SearchLocation(url: lib.appendingPathComponent("Containers"), allowNameMatch: false, checkContainerMetadata: true),
            SearchLocation(url: lib.appendingPathComponent("Application Support"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: lib.appendingPathComponent("Caches"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: lib.appendingPathComponent("Preferences"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: lib.appendingPathComponent("Saved Application State"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: lib.appendingPathComponent("WebKit"), allowNameMatch: false, checkContainerMetadata: false)
        ]
    }

    private func standardSearchLocations(home: String) -> [SearchLocation] {
        let homeURL = URL(fileURLWithPath: home)
        let userLib = homeURL.appendingPathComponent("Library")
        let sysLib = URL(fileURLWithPath: "/Library")

        var locs: [SearchLocation] = [
            // User Home & Dotfiles (technical/exact only for home root to avoid deleting user project folders)
            SearchLocation(url: homeURL.appendingPathComponent(".config"), allowNameMatch: true, checkContainerMetadata: false),
            // User Library
            SearchLocation(url: userLib.appendingPathComponent("Application Scripts"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Application Support"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Application Support/CrashReporter"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Caches"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Caches/org.sparkle-project.Sparkle"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Caches/SentryCrash"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Containers"), allowNameMatch: false, checkContainerMetadata: true),
            SearchLocation(url: userLib.appendingPathComponent("Group Containers"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Daemon Containers"), allowNameMatch: false, checkContainerMetadata: true),
            SearchLocation(url: userLib.appendingPathComponent("Cookies"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("HTTPStorages"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("WebKit"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Internet Plug-Ins"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("PreferencePanes"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Services"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("LaunchAgents"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Logs"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Logs/DiagnosticReports"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Preferences"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Preferences/ByHost"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("SyncedPreferences"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: userLib.appendingPathComponent("Saved Application State"), allowNameMatch: false, checkContainerMetadata: false),
            // System Library & Shared
            SearchLocation(url: sysLib.appendingPathComponent("Application Support"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: sysLib.appendingPathComponent("Application Support/CrashReporter"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: sysLib.appendingPathComponent("Caches"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: sysLib.appendingPathComponent("Extensions"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: sysLib.appendingPathComponent("Internet Plug-Ins"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: sysLib.appendingPathComponent("LaunchAgents"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: sysLib.appendingPathComponent("LaunchDaemons"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: sysLib.appendingPathComponent("Logs"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: sysLib.appendingPathComponent("Logs/DiagnosticReports"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: sysLib.appendingPathComponent("Preferences"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: sysLib.appendingPathComponent("PrivilegedHelperTools"), allowNameMatch: false, checkContainerMetadata: false),
            SearchLocation(url: URL(fileURLWithPath: "/Users/Shared/Library/Application Support"), allowNameMatch: true, checkContainerMetadata: false),
            SearchLocation(url: URL(fileURLWithPath: "/private/var/db/receipts"), allowNameMatch: false, checkContainerMetadata: false)
        ]

        // Per-user Darwin cache & temp dirs (`/private/var/folders/.../C` and `/T`)
        if let darwinCache = Self.darwinUserDirectory(confName: _CS_DARWIN_USER_CACHE_DIR) {
            locs.append(SearchLocation(url: darwinCache, allowNameMatch: false, checkContainerMetadata: false))
        }
        if let darwinTemp = Self.darwinUserDirectory(confName: _CS_DARWIN_USER_TEMP_DIR) {
            locs.append(SearchLocation(url: darwinTemp, allowNameMatch: false, checkContainerMetadata: false))
        }
        return locs
    }

    private static func darwinUserDirectory(confName: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(confName, &buffer, buffer.count)
        guard len > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func readContainerMetadataIdentifier(at containerURL: URL) -> String? {
        let meta = containerURL.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let data = try? Data(contentsOf: meta),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let id = plist["MCMMetadataIdentifier"] as? String, !id.isEmpty else {
            return nil
        }
        return id
    }

    private struct IdentityProfile {
        let rawBundleID: String
        let normalizedBundleID: String
        /// Parent bundle ID (dot form) when this app is itself a helper (`com.vendor.app.helper`).
        let rawBaseBundleID: String
        let bundleLastTwo: String
        let normalizedAppName: String
        let normalizedPathName: String
        let versionStrippedName: String
        /// Whole word tokens of the version-stripped app name (e.g. ["notion"]).
        let nameWords: [String]
        let companyName: String
        let teamID: String
        /// App Group / iCloud identifiers owned exclusively by this app (lowercased, raw form).
        let ownedGroups: [String]
        /// Normalized form of `ownedGroups` (min length 5).
        let entitlements: [String]
        let executableTokens: [String]
    }

    private func buildIdentityProfile(for app: InstalledAppEntry, sharedGroupIDs: Set<String>) -> IdentityProfile {
        let rawBID = app.bundleIdentifier.lowercased()
        let normBID = CleanerFormatters.normalizedToken(rawBID)
        let parts = rawBID.split(separator: ".").map(String.init)

        var baseBID = ""
        if parts.count >= 4, let last = parts.last, Self.helperBundleSuffixes.contains(last) {
            baseBID = parts.dropLast().joined(separator: ".")
        }

        let lastTwo = parts.count >= 2
            ? CleanerFormatters.normalizedToken(parts.suffix(2).joined(separator: "."))
            : ""

        let company: String = {
            guard parts.count >= 3 else { return "" }
            let mid = CleanerFormatters.normalizedToken(parts[1])
            let genericVendors: Set<String> = ["apple", "google", "microsoft", "adobe", "jetbrains", "mozilla", "github", "electron", "tauri", "app", "mac", "macos", "desktop"]
            return (mid.count >= 4 && !genericVendors.contains(mid)) ? mid : ""
        }()

        let normName = CleanerFormatters.normalizedToken(app.name)
        let pathStem = app.url.deletingPathExtension().lastPathComponent
        let normPath = CleanerFormatters.normalizedToken(pathStem)
        let strippedRaw = Self.versionStrippedName(app.name)
        let stripped = CleanerFormatters.normalizedToken(strippedRaw)

        let ownedGroups = app.entitlementGroups
            .map { $0.lowercased() }
            .filter { !$0.isEmpty && !sharedGroupIDs.contains($0) }
        let normEnts = ownedGroups.map { CleanerFormatters.normalizedToken($0) }.filter { $0.count >= 5 }
        let normExecs = app.executableNames.map { CleanerFormatters.normalizedToken($0) }.filter { $0.count >= 5 }

        return IdentityProfile(
            rawBundleID: rawBID,
            normalizedBundleID: normBID,
            rawBaseBundleID: baseBID,
            bundleLastTwo: lastTwo,
            normalizedAppName: normName,
            normalizedPathName: normPath,
            versionStrippedName: stripped,
            nameWords: Self.wordTokens(strippedRaw),
            companyName: company,
            teamID: (app.teamIdentifier ?? "").lowercased(),
            ownedGroups: ownedGroups,
            entitlements: normEnts,
            executableTokens: normExecs
        )
    }

    /// Strips a trailing version number ("Foo 2" / "Foo 12.3" → "Foo").
    private static func versionStrippedName(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s+[0-9]+(\.[0-9]+)*$"#, with: "", options: .regularExpression)
    }

    /// Lowercased alphanumeric word tokens ("Notion Calendar" → ["notion", "calendar"],
    /// "Brave-Browser-Beta" → ["brave", "browser", "beta"]).
    static func wordTokens(_ raw: String) -> [String] {
        raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// True when `identifier` occurs in `candidate` as whole dot-separated components: `id`, `id.*`,
    /// `*.id` or `*.id.*` (team- or group-prefixed names such as `TEAMID.com.vendor.app`).
    /// Never a raw substring: `com.microsoft.vscodeinsiders` does not contain `com.microsoft.vscode`.
    static func containsIdentifier(_ candidate: String, _ identifier: String) -> Bool {
        guard !identifier.isEmpty, !candidate.isEmpty else { return false }
        return candidate == identifier
            || candidate.hasPrefix(identifier + ".")
            || candidate.hasSuffix("." + identifier)
            || candidate.contains("." + identifier + ".")
    }

    /// `identifier` owns `candidate` unless a longer (more specific) competing identifier also matches it,
    /// e.g. `com.google.chrome.canary.plist` belongs to Canary, not to `com.google.chrome`.
    private static func owns(_ candidate: String, identifier: String, competitors: Set<String>) -> Bool {
        guard containsIdentifier(candidate, identifier) else { return false }
        return !competitors.contains { $0.count > identifier.count && containsIdentifier(candidate, $0) }
    }

    /// Whole-token name match: `candidateWords` starts with this app's name words, and no other installed
    /// app's name matches the same candidate at least as specifically ("Notion Calendar" loses to an
    /// installed "Notion Calendar" when scanning "Notion").
    private static func wordPrefixMatch(_ candidateWords: [String], nameWords: [String], competitors: [[String]]) -> Bool {
        guard !nameWords.isEmpty, candidateWords.starts(with: nameWords) else { return false }
        return !competitors.contains { other in
            other.count >= nameWords.count && candidateWords.starts(with: other)
        }
    }

    private func matchToken(
        _ candidateRaw: String,
        context: MatchContext,
        allowNameMatch: Bool
    ) -> String? {
        let profile = context.profile
        let sensitivity = context.sensitivity
        let candidateLower = candidateRaw.lowercased()
        let norm = CleanerFormatters.normalizedToken(candidateRaw)
        guard norm.count >= 3 else { return nil }

        if let rule = context.rule {
            for ex in rule.excludeTokens where candidateLower.contains(ex) || norm.contains(ex) {
                return nil
            }
        }

        // 1. Bundle ID: exact or whole dot-component match; the most specific installed (or known
        //    sibling-channel) identifier wins, so siblings' namespaces are never claimed.
        if !profile.rawBundleID.isEmpty && profile.rawBundleID.contains(".") {
            if Self.owns(candidateLower, identifier: profile.rawBundleID, competitors: context.competingBundleIDs) {
                return "Bundle ID"
            }
        }
        if context.competingBundleIDs.contains(where: { Self.containsIdentifier(candidateLower, $0) }) {
            return nil
        }
        if profile.normalizedBundleID.count >= 6 && norm == profile.normalizedBundleID {
            return "Bundle ID"
        }
        // Helper apps inherit their parent's namespace only while the parent app itself is not installed.
        if !profile.rawBaseBundleID.isEmpty,
           !context.competingBundleIDs.contains(profile.rawBaseBundleID),
           Self.owns(candidateLower, identifier: profile.rawBaseBundleID, competitors: context.competingBundleIDs) {
            return "Base Bundle ID"
        }

        // 2. Entitlement groups exclusively owned by this app (exact only; shared groups were removed).
        for group in profile.ownedGroups where candidateLower == group {
            return "Entitlement Group"
        }
        for ent in profile.entitlements where norm == ent {
            return "Entitlement Group"
        }

        // Name-derived matches are void when another installed app has the very same name.
        let nameIsContested = context.competingNames.contains(norm)

        // 3. App name & path name exact matches (allowed in App Support / Caches / Logs / etc.)
        if allowNameMatch && !nameIsContested {
            if profile.normalizedAppName.count >= 4 && norm == profile.normalizedAppName {
                return "App Name"
            }
            if profile.normalizedPathName.count >= 4 && norm == profile.normalizedPathName {
                return "Bundle Name"
            }
            for exec in profile.executableTokens where norm == exec {
                return "Executable Name"
            }
        }

        if let rule = context.rule, !nameIsContested {
            for extra in rule.extraIncludeTokens where norm == extra {
                return "App Rule"
            }
        }

        // 4. Enhanced tier: last-two bundle segments and whole-token name prefixes
        //    ("Notion Helper" for "Notion"), never raw substrings.
        if sensitivity.rawValue >= CleanerSearchSensitivity.enhanced.rawValue {
            if !nameIsContested && profile.bundleLastTwo.count >= 6 && norm == profile.bundleLastTwo {
                return "Bundle Family"
            }
            if allowNameMatch && !nameIsContested {
                if profile.versionStrippedName.count >= 5 && norm == profile.versionStrippedName {
                    return "App Name (Enhanced)"
                }
                if profile.versionStrippedName.count >= 5,
                   Self.wordPrefixMatch(Self.wordTokens(candidateRaw), nameWords: profile.nameWords, competitors: context.competingNameWords) {
                    return "App Name Tokens (Enhanced)"
                }
            }
        }

        // 5. Deep tier: Team ID / vendor folders, only in name-match locations and only when no
        //    other installed app shares the same Team ID / vendor (e.g. Microsoft's UBF8T346G9.*).
        if sensitivity == .deep && allowNameMatch {
            if !context.teamIDShared && profile.teamID.count == 10
                && (candidateLower == profile.teamID || candidateLower.hasPrefix(profile.teamID + ".")) {
                return "Team ID (Deep)"
            }
            if !context.vendorShared && !nameIsContested && profile.companyName.count >= 5 && norm == profile.companyName {
                return "Vendor (Deep)"
            }
        }

        return nil
    }

    private func scanVendorSubfolders(
        in roots: [URL],
        context: MatchContext,
        home: String,
        exclusions: [String],
        rule: DisambiguationRule?,
        into candidates: inout [String: (url: URL, reason: String, isLinked: Bool, isContainerUUID: Bool)]
    ) {
        let fm = FileManager.default
        for root in roots {
            guard let firstLevel = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            let rootIsLibrary = root.lastPathComponent == "Library"
            for subdir in firstLevel {
                let vals = try? subdir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard vals?.isDirectory == true, vals?.isSymbolicLink != true else { continue }
                let lowerName = subdir.lastPathComponent.lowercased()
                if lowerName.hasPrefix("com.apple.") || Self.skippedLibrarySubdirectories.contains(lowerName) {
                    continue
                }
                if rootIsLibrary && Self.standardLibraryContainers.contains(lowerName) {
                    continue
                }
                guard let nested = try? fm.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                    continue
                }
                var matchedChildren: [(URL, String)] = []
                for child in nested {
                    let cleanChild = child.standardizedFileURL
                    if isGloballySkipped(cleanChild, home: home, exclusions: exclusions, rule: rule) { continue }
                    let stem = cleanChild.deletingPathExtension().lastPathComponent
                    if let reason = matchToken(stem, context: context, allowNameMatch: true) {
                        matchedChildren.append((cleanChild, reason))
                    }
                }
                // Only the matched children are claimed; the vendor parent itself is never promoted.
                for (childURL, reason) in matchedChildren {
                    candidates[childURL.path] = (childURL, reason, false, false)
                }
            }
        }
    }

    private func isGloballySkipped(
        _ url: URL,
        home: String,
        exclusions: [String],
        rule: DisambiguationRule?
    ) -> Bool {
        let path = url.standardizedFileURL.path
        let lowerPath = path.lowercased()
        let lowerName = url.lastPathComponent.lowercased()

        if lowerName == ".ds_store" || lowerName == ".localized" { return true }
        if lowerPath.hasPrefix((home + "/.Trash").lowercased()) { return true }
        if lowerPath.contains("/library/systemextensions") { return true }
        if lowerPath.contains("com.apple.passwordmanager") || lowerPath.contains("mobiledocuments") { return true }
        if lowerName.hasPrefix("dev.ztat.app") || lowerName == "ztat" || lowerName == "ztat.app" { return true }

        // Never sweep user source repositories
        if SafePathGuard.isInsideSourceRepository(url) { return true }

        // User-configured App Exclusions (exact path or substring token)
        for ex in exclusions {
            let trimmed = ex.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            if path == expanded || path.hasPrefix(expanded + "/") || lowerPath.contains(trimmed.lowercased()) {
                return true
            }
        }
        return false
    }
}
