// SPDX-License-Identifier: GPL-3.0-or-later
// Parallel macOS app discovery engine: standard/nested apps, wrapped iOS apps,
// web apps, Steam games, Homebrew Caskroom correlation, Sparkle/MAS badges,
// Mach-O architecture inspection, static code-signing metadata, and Disk Volume stats.

import AppKit
import CoreServices
import Foundation
import Security
import ZtatCore

/// Result of validating an externally supplied `.app` bundle (deep link, drag-and-drop, Finder Service).
public enum SingleAppInspectionResult: Sendable {
    /// The bundle was readable and may be handed to the uninstaller.
    case accepted(InstalledAppEntry)
    /// The bundle is protected (macOS system app or ztat itself); `reason` is localized for the UI.
    case rejected(reason: String)
    /// The path is not a readable `.app` bundle.
    case unreadable
}

public final class AppDiscoveryEngine: @unchecked Sendable {
    public static let shared = AppDiscoveryEngine()

    private init() {}

    /// Inspects mounted local/external volumes for the Disk Volume Dashboard.
    public func loadDiskVolumes() -> [DiskVolumeInfo] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsRootFileSystemKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsLocalKey
        ]
        guard let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return []
        }
        var results: [DiskVolumeInfo] = []
        for url in urls {
            guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard vals.volumeIsLocal != false else { continue }
            let total = Int64(vals.volumeTotalCapacity ?? 0)
            guard total > 0 else { continue }
            let important = vals.volumeAvailableCapacityForImportantUsage ?? Int64(vals.volumeAvailableCapacity ?? 0)
            let opportunistic = vals.volumeAvailableCapacityForOpportunisticUsage ?? important
            let isRoot = vals.volumeIsRootFileSystem == true || url.path == "/"
            let removable = (vals.volumeIsRemovable == true || vals.volumeIsEjectable == true) && !isRoot
            let name = vals.volumeName ?? url.lastPathComponent
            results.append(DiskVolumeInfo(
                id: url.path,
                name: name.isEmpty ? "Macintosh HD" : name,
                mountURL: url,
                totalBytes: total,
                availableBytes: max(0, important),
                opportunisticAvailableBytes: max(0, opportunistic),
                isRootVolume: isRoot,
                isRemovable: removable
            ))
        }
        return results.sorted { lhs, rhs in
            if lhs.isRootVolume != rhs.isRootVolume { return lhs.isRootVolume }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Discovers all installed apps across configured scan folders, enriched with architecture,
    /// code-signing Team ID/entitlements, Homebrew cask token, Sparkle, and MAS flags.
    public func discoverApps(in folders: [String]) async -> [InstalledAppEntry] {
        await Task.detached(priority: .userInitiated) {
            let caskIndex = self.buildHomebrewCaskIndex()
            let discoveredURLs = self.collectAppURLs(in: folders)
            let home = (NSHomeDirectory() as NSString).standardizingPath

            var entries: [InstalledAppEntry] = []
            entries.reserveCapacity(discoveredURLs.count)

            await withTaskGroup(of: InstalledAppEntry?.self) { group in
                for item in discoveredURLs {
                    group.addTask {
                        self.inspectApp(
                            at: item.url,
                            isNested: item.isNested,
                            home: home,
                            caskIndex: caskIndex,
                            isAlreadyInTrash: false
                        )
                    }
                }
                for await entry in group {
                    if let entry {
                        entries.append(entry)
                    }
                }
            }

            // Deduplicate by standardized path and hide protected apps (system / non-MAS com.apple.* / ztat),
            // using the same policy that blocks deep links, drag-and-drop and removal.
            var seen = Set<String>()
            let unique = entries.filter { entry in
                seen.insert(entry.id).inserted && self.restrictionReason(for: entry) == nil
            }
            return unique.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }.value
    }

    /// Inspects a single arbitrary `.app` bundle (drag-and-drop, Trash Sentinel, Finder Services, URL scheme).
    /// Returns `nil` for unreadable bundles and for protected apps (macOS system apps, ztat itself);
    /// use `inspectSingleAppForUninstall(at:)` to obtain a user-facing rejection reason.
    public func inspectSingleApp(at url: URL) async -> InstalledAppEntry? {
        if case .accepted(let entry) = await inspectSingleAppForUninstall(at: url) {
            return entry
        }
        return nil
    }

    /// Validates and inspects an externally supplied `.app` bundle. Protected apps are rejected with a
    /// localized reason so callers can explain why the uninstaller refused the request.
    public func inspectSingleAppForUninstall(at url: URL) async -> SingleAppInspectionResult {
        await Task.detached(priority: .userInitiated) {
            let clean = url.standardizedFileURL
            guard clean.pathExtension.lowercased() == "app" else { return .unreadable }
            if let reason = self.restrictionReason(forAppAt: clean) {
                return .rejected(reason: reason)
            }
            let home = (NSHomeDirectory() as NSString).standardizingPath
            let trashRoot = (home as NSString).appendingPathComponent(".Trash")
            let inTrash = clean.path.hasPrefix(trashRoot + "/")
            let caskIndex = self.buildHomebrewCaskIndex()
            guard let entry = self.inspectApp(
                at: clean,
                isNested: false,
                home: home,
                caskIndex: caskIndex,
                isAlreadyInTrash: inTrash
            ) else {
                return .unreadable
            }
            if let reason = self.restrictionReason(for: entry) {
                return .rejected(reason: reason)
            }
            return .accepted(entry)
        }.value
    }

    // MARK: - Protected App Policy

    /// Returns a localized reason when `app` must never be uninstalled, reset or modified by the cleaner
    /// (macOS system apps by location or `com.apple.*` identity, or ztat itself); `nil` when allowed.
    public func restrictionReason(for app: InstalledAppEntry) -> String? {
        if let reason = restrictionReason(forAppAt: app.url) { return reason }
        if app.actualBundleURL.standardizedFileURL != app.url.standardizedFileURL,
           let reason = restrictionReason(forAppAt: app.actualBundleURL) {
            return reason
        }
        return restrictionReason(
            forBundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            isAppStoreInstall: app.isAppStore
        )
    }

    /// Location-based protection check, evaluated on both the given and the symlink-resolved path so an
    /// alias such as `/tmp/x.app -> /System/Applications/Notes.app` is rejected as well.
    public func restrictionReason(forAppAt url: URL) -> String? {
        let clean = url.standardizedFileURL.path
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        let name = url.deletingPathExtension().lastPathComponent
        for path in [clean, resolved] {
            if Self.ownBundlePaths.contains(path) || Self.isOwnBundleName((path as NSString).lastPathComponent) {
                return Self.ownBundleRejectionMessage
            }
            if isRestrictedAppPath(path, selfPath: "") {
                return Self.systemAppRejectionMessage(name: name)
            }
        }
        return nil
    }

    /// Identity-based protection check: Apple system apps (`com.apple.*`) and ztat's own bundle.
    /// Apple apps installed from the Mac App Store (Xcode, Pages, Keynote…) carry a `_MASReceipt`, live
    /// outside the sealed system volume and are user-removable, so they stay allowed — matching the
    /// discovered-apps list. Lipo applies its own stricter `com.apple.*` refusal independently.
    public func restrictionReason(
        forBundleIdentifier bundleIdentifier: String,
        appName: String,
        isAppStoreInstall: Bool = false
    ) -> String? {
        let lower = bundleIdentifier.lowercased()
        guard !lower.isEmpty else { return nil }
        if Self.ownBundleIdentifiers.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") }) {
            return Self.ownBundleRejectionMessage
        }
        if lower.hasPrefix("com.apple."), !isAppStoreInstall {
            return Self.systemAppRejectionMessage(name: appName)
        }
        return nil
    }

    private static let ownBundlePaths: Set<String> = {
        let url = Bundle.main.bundleURL.standardizedFileURL
        return Set([url.path, url.resolvingSymlinksInPath().path].filter { !$0.isEmpty })
    }()

    private static let ownBundleIdentifiers: Set<String> = {
        var ids: Set<String> = ["dev.ztat.app"]
        if let own = Bundle.main.bundleIdentifier?.lowercased(), !own.isEmpty {
            ids.insert(own)
        }
        return ids
    }()

    private static func isOwnBundleName(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return lower == "ztat.app" || lower == "ztat-dev.app"
    }

    private static var ownBundleRejectionMessage: String {
        ZtatL10n.tr("不能用 ztat 卸载或修改 ztat 自身。", "ztat cannot uninstall or modify itself.")
    }

    private static func systemAppRejectionMessage(name: String) -> String {
        ZtatL10n.tr(
            "「\(name)」是受 macOS 保护的系统应用，已拒绝处理。",
            "\(name) is a protected macOS system app and was not processed."
        )
    }

    // MARK: - Folder Traversal

    private func collectAppURLs(in folders: [String]) -> [(url: URL, isNested: Bool)] {
        let fm = FileManager.default
        let selfPath = (Bundle.main.bundlePath as NSString).standardizingPath
        var found: [(url: URL, isNested: Bool)] = []
        var visited = Set<String>()

        func walk(_ dir: URL, depth: Int) {
            guard depth <= 3 else { return }
            let cleanDir = dir.standardizedFileURL
            guard visited.insert(cleanDir.path).inserted else { return }
            guard let children = try? fm.contentsOfDirectory(
                at: cleanDir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for child in children {
                let vals = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if vals?.isSymbolicLink == true { continue }
                let path = child.standardizedFileURL.path
                if isRestrictedAppPath(path, selfPath: selfPath) { continue }

                if child.pathExtension.lowercased() == "app" {
                    found.append((child.standardizedFileURL, depth > 0))
                } else if vals?.isDirectory == true {
                    walk(child, depth: depth + 1)
                }
            }
        }

        for folder in folders {
            let expanded = (folder as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            if fm.fileExists(atPath: url.path) {
                walk(url, depth: 0)
            }
        }
        return found
    }

    private func isRestrictedAppPath(_ path: String, selfPath: String) -> Bool {
        if !selfPath.isEmpty && path == selfPath { return true }
        let lower = path.lowercased()
        if lower == "/applications/safari.app" || lower.hasPrefix("/applications/utilities/") || lower == "/applications/utilities" {
            return true
        }
        if lower.hasPrefix("/system/") { return true }
        let baseName = (path as NSString).lastPathComponent.lowercased()
        if baseName == "ztat.app" || baseName == "ztat-dev.app" { return true }
        return false
    }

    // MARK: - Single Bundle Inspection

    private func inspectApp(
        at outerURL: URL,
        isNested: Bool,
        home: String,
        caskIndex: HomebrewCaskLookup,
        isAlreadyInTrash: Bool
    ) -> InstalledAppEntry? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: outerURL.path) else { return nil }

        // Detect Wrapped iOS/iPadOS apps (<App>.app/Wrapper/<Inner>.app)
        var actualBundleURL = outerURL
        var isWrappediOS = false
        let wrapperDir = outerURL.appendingPathComponent("Wrapper", isDirectory: true)
        if fm.fileExists(atPath: wrapperDir.path),
           let wrappedChildren = try? fm.contentsOfDirectory(at: wrapperDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
           let innerApp = wrappedChildren.first(where: { $0.pathExtension.lowercased() == "app" }) {
            actualBundleURL = innerApp
            isWrappediOS = true
        }

        var plist = readInfoPlist(for: actualBundleURL)
        var isSteamGame = false
        var steamAppID: String? = nil

        // Detect Steam launcher stubs lacking standard Info.plist
        if plist == nil {
            let runScript = outerURL.appendingPathComponent("Contents/MacOS/run.sh")
            if let scriptText = try? String(contentsOf: runScript, encoding: .utf8),
               let range = scriptText.range(of: #"steam://run/([0-9]+)"#, options: .regularExpression) {
                isSteamGame = true
                let matched = String(scriptText[range])
                steamAppID = matched.replacingOccurrences(of: "steam://run/", with: "")
                let appNameStem = outerURL.deletingPathExtension().lastPathComponent
                let steamCommon = URL(fileURLWithPath: home)
                    .appendingPathComponent("Library/Application Support/Steam/steamapps/common", isDirectory: true)
                    .appendingPathComponent(appNameStem, isDirectory: true)
                if let inner = findInnerAppBundle(in: steamCommon) {
                    actualBundleURL = inner
                    plist = readInfoPlist(for: inner)
                }
            }
        }

        let fileStem = outerURL.deletingPathExtension().lastPathComponent
        let displayName = (plist?["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (plist?["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? fileStem

        let bundleID = (plist?["CFBundleIdentifier"] as? String) ?? ""
        let shortVer = plist?["CFBundleShortVersionString"] as? String
        let buildVer = plist?["CFBundleVersion"] as? String
        let version = shortVer?.isEmpty == false ? shortVer! : (buildVer ?? "—")

        let execName = plist?["CFBundleExecutable"] as? String ?? ""
        let isTemplate = (plist?["LSTemplateApplication"] as? Bool) == true
        let isWebApp = isTemplate || execName == "app_mode_loader"

        let hasMASReceipt = fm.fileExists(atPath: actualBundleURL.appendingPathComponent("Contents/_MASReceipt/receipt").path)
            || fm.fileExists(atPath: outerURL.appendingPathComponent("Wrapper/iTunesMetadata.plist").path)

        let hasSparkle: Bool = {
            if bundleID.lowercased().hasSuffix("-setapp") { return false }
            if let feed = plist?["SUFeedURL"] as? String, !feed.isEmpty { return true }
            return fm.fileExists(atPath: actualBundleURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework").path)
        }()

        let arch = detectPrimaryArchitecture(in: actualBundleURL, executableName: execName)
        let (teamID, entitlements) = readStaticCodeSigningInfo(at: actualBundleURL)
        let executableNames = collectExecutableNames(in: actualBundleURL)
        let caskToken = caskIndex.match(appURL: outerURL)

        let md = readSpotlightMetadata(for: outerURL)
        let rv = try? outerURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey])
        let size = md.logicalSize ?? SafeDeletionEngine.logicalSize(of: outerURL)

        return InstalledAppEntry(
            id: outerURL.standardizedFileURL.path,
            url: outerURL.standardizedFileURL,
            actualBundleURL: actualBundleURL.standardizedFileURL,
            name: displayName,
            bundleIdentifier: bundleID,
            version: version,
            isSystemDomain: !outerURL.path.hasPrefix(home + "/"),
            isNested: isNested,
            isWrappediOS: isWrappediOS,
            isWebApp: isWebApp,
            isSteamGame: isSteamGame,
            steamAppID: steamAppID,
            isAppStore: hasMASReceipt,
            hasSparkle: hasSparkle,
            homebrewCaskToken: caskToken,
            architecture: arch,
            teamIdentifier: teamID,
            entitlementGroups: entitlements,
            executableNames: executableNames,
            bundleSize: size,
            dateCreated: md.created ?? rv?.creationDate,
            dateModified: md.modified ?? rv?.contentModificationDate,
            dateAdded: md.added ?? rv?.addedToDirectoryDate,
            lastUsedDate: md.lastUsed,
            isAlreadyInTrash: isAlreadyInTrash
        )
    }

    private func readInfoPlist(for bundleURL: URL) -> [String: Any]? {
        let candidates = [
            bundleURL.appendingPathComponent("Contents/Info.plist"),
            bundleURL.appendingPathComponent("Info.plist")
        ]
        for candidate in candidates {
            if let data = try? Data(contentsOf: candidate),
               let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                return obj
            }
        }
        return nil
    }

    private func findInnerAppBundle(in dir: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        return items.first(where: { $0.pathExtension.lowercased() == "app" })
    }

    private func collectExecutableNames(in bundleURL: URL) -> [String] {
        let fm = FileManager.default
        let skip: Set<String> = ["crashhandler", "crash handler", "electron", "applet", "launcher"]
        var names: [String] = []
        let macOSDir = bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: macOSDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for f in files {
                let stem = f.deletingPathExtension().lastPathComponent
                if stem.count >= 5 && !skip.contains(stem.lowercased()) {
                    names.append(stem)
                }
            }
        }
        return Array(Set(names))
    }

    private func detectPrimaryArchitecture(in bundleURL: URL, executableName: String) -> AppArchitecture {
        let fm = FileManager.default
        let candidates: [URL] = [
            executableName.isEmpty ? nil : bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)"),
            executableName.isEmpty ? nil : bundleURL.appendingPathComponent(executableName)
        ].compactMap { $0 }

        var execURL = candidates.first(where: { fm.fileExists(atPath: $0.path) })
        if execURL == nil {
            let macOSDir = bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
            execURL = (try? fm.contentsOfDirectory(at: macOSDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.first
        }
        guard let url = execURL else { return .unknown }
        return MachOLipoEngine.inspectBinaryArchitecture(at: url)
    }

    private func readStaticCodeSigningInfo(at bundleURL: URL) -> (teamID: String?, groups: [String]) {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode else {
            return (nil, [])
        }
        var infoCF: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else {
            return (nil, [])
        }
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        var groups: [String] = []
        if let entDict = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            if let appGroups = entDict["com.apple.security.application-groups"] as? [String] {
                groups.append(contentsOf: appGroups)
            }
            if let iCloudGroups = entDict["com.apple.developer.icloud-container-identifiers"] as? [String] {
                groups.append(contentsOf: iCloudGroups)
            }
        }
        return (teamID, Array(Set(groups)))
    }

    private struct SpotlightAppMeta {
        let logicalSize: Int64?
        let created: Date?
        let modified: Date?
        let added: Date?
        let lastUsed: Date?
    }

    private func readSpotlightMetadata(for url: URL) -> SpotlightAppMeta {
        guard let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else {
            return SpotlightAppMeta(logicalSize: nil, created: nil, modified: nil, added: nil, lastUsed: nil)
        }
        let sizeNum = MDItemCopyAttribute(mdItem, "kMDItemLogicalSize" as CFString) as? NSNumber
        let created = MDItemCopyAttribute(mdItem, kMDItemFSCreationDate) as? Date
        let modified = MDItemCopyAttribute(mdItem, kMDItemFSContentChangeDate) as? Date
        let added = MDItemCopyAttribute(mdItem, kMDItemDateAdded) as? Date
        let lastUsed = MDItemCopyAttribute(mdItem, kMDItemLastUsedDate) as? Date
        return SpotlightAppMeta(
            logicalSize: sizeNum?.int64Value,
            created: created,
            modified: modified,
            added: added,
            lastUsed: lastUsed
        )
    }

    // MARK: - Homebrew Caskroom Fast Index

    /// Exact app → cask correlation. Only two kinds of evidence are accepted, because the token is fed
    /// to `brew uninstall --zap`, which permanently deletes the cask's declared data:
    /// 1. the `Caskroom/<token>/<version>/<Name>.app` symlink Homebrew leaves behind, which records the
    ///    exact installed location of the bundle;
    /// 2. `app` artifacts declared in the cask's install receipt / cached cask JSON, used only for
    ///    casks whose installed location is unknown and only when exactly one cask declares that file name.
    /// Display-name or bundle-ID-segment heuristics are deliberately NOT used.
    private struct HomebrewCaskLookup {
        /// Lowercased standardized absolute `.app` path → cask token.
        var tokenByAppPath: [String: String] = [:]
        /// Lowercased `.app` file name → tokens declaring it (only casks with an unknown install path).
        var tokensByAppFileName: [String: Set<String>] = [:]
        /// Casks whose installed `.app` location is known exactly.
        var tokensWithKnownAppPath: Set<String> = []

        mutating func registerInstalledApp(path: String, token: String) {
            let key = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
            tokenByAppPath[key] = token
            tokensWithKnownAppPath.insert(token)
        }

        mutating func registerDeclaredApp(fileName: String, token: String) {
            let key = fileName.lowercased()
            guard key.hasSuffix(".app") else { return }
            tokensByAppFileName[key, default: []].insert(token)
        }

        func match(appURL: URL) -> String? {
            let clean = appURL.standardizedFileURL
            for path in [clean.path, clean.resolvingSymlinksInPath().path] {
                if let token = tokenByAppPath[path.lowercased()] {
                    return token
                }
            }
            // File-name fallback only for bundles installed where Homebrew installs casks: a stray copy
            // such as `~/Downloads/Firefox.app` must never resolve to the `firefox` cask (zap would then
            // wipe the real install's data).
            guard Self.isInCaskAppDirectory(clean) else { return nil }
            let declared = (tokensByAppFileName[clean.lastPathComponent.lowercased()] ?? [])
                .subtracting(tokensWithKnownAppPath)
            return declared.count == 1 ? declared.first : nil
        }

        /// True when both the standardized and the symlink-resolved parent directory are exactly
        /// `/Applications` or `~/Applications`.
        private static func isInCaskAppDirectory(_ appURL: URL) -> Bool {
            let home = (NSHomeDirectory() as NSString).standardizingPath
            let allowed: Set<String> = ["/applications", (home + "/Applications").lowercased()]
            let parents = [appURL.standardizedFileURL, appURL.standardizedFileURL.resolvingSymlinksInPath()]
                .map { $0.deletingLastPathComponent().standardizedFileURL.path.lowercased() }
            return parents.allSatisfy(allowed.contains)
        }
    }

    private func buildHomebrewCaskIndex() -> HomebrewCaskLookup {
        var lookup = HomebrewCaskLookup()
        let fm = FileManager.default
        let roots = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]

        for root in roots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard let tokens = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for tokenDir in tokens {
                let token = tokenDir.lastPathComponent

                // 1. Installed version folders: `<Name>.app` symlinks point at the exact installed bundle.
                if let versions = try? fm.contentsOfDirectory(at: tokenDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for verDir in versions {
                        guard let items = try? fm.contentsOfDirectory(at: verDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                            continue
                        }
                        for item in items where item.pathExtension.lowercased() == "app" {
                            if let destination = try? fm.destinationOfSymbolicLink(atPath: item.path) {
                                let absolute = destination.hasPrefix("/")
                                    ? destination
                                    : verDir.appendingPathComponent(destination).path
                                lookup.registerInstalledApp(path: absolute, token: token)
                            } else {
                                lookup.registerDeclaredApp(fileName: item.lastPathComponent, token: token)
                            }
                        }
                    }
                }

                // 2. Declared `app` artifacts (install receipt and cached cask JSON).
                for jsonURL in caskMetadataJSONFiles(tokenDir: tokenDir, token: token) {
                    guard let data = try? Data(contentsOf: jsonURL),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }
                    for key in ["uninstall_artifacts", "artifacts"] {
                        guard let artifacts = obj[key] as? [[String: Any]] else { continue }
                        for fileName in Self.declaredAppFileNames(in: artifacts) {
                            lookup.registerDeclaredApp(fileName: fileName, token: token)
                        }
                    }
                }
            }
        }
        return lookup
    }

    /// `Caskroom/<token>/.metadata/INSTALL_RECEIPT.json` plus every cached
    /// `.metadata/<version>/<timestamp>/Casks/<token>.json`.
    private func caskMetadataJSONFiles(tokenDir: URL, token: String) -> [URL] {
        let fm = FileManager.default
        let metaDir = tokenDir.appendingPathComponent(".metadata", isDirectory: true)
        var files: [URL] = []
        let receipt = metaDir.appendingPathComponent("INSTALL_RECEIPT.json")
        if fm.fileExists(atPath: receipt.path) {
            files.append(receipt)
        }
        let versions = (try? fm.contentsOfDirectory(at: metaDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for versionDir in versions {
            let stamps = (try? fm.contentsOfDirectory(at: versionDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for stampDir in stamps + [versionDir] {
                let caskJSON = stampDir.appendingPathComponent("Casks/\(token).json")
                if fm.fileExists(atPath: caskJSON.path) {
                    files.append(caskJSON)
                }
            }
        }
        return files
    }

    /// Installed `.app` file names declared by `app` artifacts: `{"app": ["Foo.app"]}` or, for renamed
    /// installs, `{"app": ["Foo.app", {"target": "Bar.app"}]}` (the target is the installed name).
    private static func declaredAppFileNames(in artifacts: [[String: Any]]) -> [String] {
        var names: [String] = []
        for artifact in artifacts {
            guard let entries = artifact["app"] as? [Any] else { continue }
            var source: String?
            var target: String?
            for entry in entries {
                if let string = entry as? String {
                    if source == nil { source = string }
                } else if let options = entry as? [String: Any], let t = options["target"] as? String {
                    target = t
                }
            }
            if let installed = target ?? source {
                names.append((installed as NSString).lastPathComponent)
            }
        }
        return names
    }
}
