// SPDX-License-Identifier: GPL-3.0-or-later
// Reversible Trash-Bundle deletion engine, hard path-safety validator,
// persistent Delete History (last 10 ops), and selective restoration.

import AppKit
import Foundation
import ZtatCore

public struct SafeDeletionOutcome: Sendable {
    public let entry: DeleteHistoryEntry?
    public let succeededCount: Int
    public let freedBytes: Int64
    public let failedItems: [(path: String, reason: String)]
}

public enum SafePathGuard {
    /// Absolute system roots and high-risk parent directories that may NEVER be trashed (exact match).
    private static let hardBlockedPaths: Set<String> = Set([
        "/",
        "/Applications",
        "/Applications/Utilities",
        "/System",
        "/System/Applications",
        "/System/Library",
        "/Library",
        "/Library/Application Support",
        "/Library/Application Support/com.apple.TCC",
        "/Library/Apple",
        "/Library/Caches",
        "/Library/Containers",
        "/Library/Developer",
        "/Library/Extensions",
        "/Library/Fonts",
        "/Library/Frameworks",
        "/Library/Internet Plug-Ins",
        "/Library/Keychains",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
        "/Library/Logs",
        "/Library/Logs/DiagnosticReports",
        "/Library/PreferencePanes",
        "/Library/Preferences",
        "/Library/PrivilegedHelperTools",
        "/Library/Audio",
        "/Library/Audio/Plug-Ins",
        "/Library/Audio/Plug-Ins/Components",
        "/Library/Audio/Plug-Ins/HAL",
        "/Library/Audio/Plug-Ins/VST",
        "/Library/Audio/Plug-Ins/VST3",
        "/Library/QuickLook",
        "/Library/Screen Savers",
        "/Library/Spotlight",
        "/Library/SystemExtensions",
        "/Users",
        "/Users/Shared",
        "/Users/Shared/Library",
        "/Users/Shared/Library/Application Support",
        "/usr",
        "/usr/bin",
        "/usr/sbin",
        "/usr/lib",
        "/usr/libexec",
        "/usr/share",
        "/usr/local",
        "/usr/local/bin",
        "/usr/local/etc",
        "/usr/local/lib",
        "/usr/local/opt",
        "/usr/local/sbin",
        "/usr/local/share",
        "/usr/local/var",
        "/opt",
        "/opt/homebrew",
        "/opt/homebrew/bin",
        "/bin",
        "/sbin",
        "/etc",
        "/var",
        "/private",
        "/private/etc",
        "/private/var",
        "/private/var/db",
        "/private/var/db/receipts",
        "/private/var/folders",
        "/private/var/log",
        "/private/var/root",
        "/private/var/vm",
        "/private/tmp",
        "/tmp",
        "/Volumes",
        "/Network",
        "/dev",
        "/cores"
    ].map { $0.lowercased() })

    /// Subtrees that are protected at any depth (lowercased, trailing slash).
    private static let hardBlockedPrefixes: [String] = [
        "/system/",
        "/bin/",
        "/sbin/",
        "/usr/bin/",
        "/usr/sbin/",
        "/usr/lib/",
        "/usr/libexec/",
        "/usr/share/",
        "/dev/",
        "/private/var/root/",
        "/private/var/vm/",
        "/library/apple/",
        "/library/keychains/",
        "/library/application support/com.apple.tcc/"
    ]

    /// Top-level folders whose direct children are whole system/volume/user roots:
    /// `/Library/<X>`, `/private/<X>`, `/Volumes/<name>`, `/Users/<name>`, `/Network/<X>`.
    private static let topLevelContainerRoots: Set<String> = ["library", "private", "volumes", "users", "network", "system"]

    /// Protected user-home subdirectories that must never be deleted as a whole root (exact match).
    private static let blockedHomeRelatives: Set<String> = Set([
        "",
        "Desktop",
        "Documents",
        "Downloads",
        "Applications",
        "Library",
        "Library/Application Support",
        "Library/Application Scripts",
        "Library/Caches",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Daemon Containers",
        "Library/HTTPStorages",
        "Library/WebKit",
        "Library/Cookies",
        "Library/LaunchAgents",
        "Library/Logs",
        "Library/Logs/DiagnosticReports",
        "Library/Preferences",
        "Library/Preferences/ByHost",
        "Library/Saved Application State",
        "Library/PreferencePanes",
        "Library/Internet Plug-Ins",
        "Library/Services",
        "Library/Audio",
        "Library/Audio/Plug-Ins",
        "Library/Fonts",
        "Library/Keychains",
        "Library/Mail",
        "Library/Messages",
        "Library/Safari",
        "Library/CloudStorage",
        "Library/Mobile Documents",
        ".Trash",
        ".config",
        ".ssh",
        ".gnupg",
        "Movies",
        "Music",
        "Pictures",
        "Public"
    ].map { $0.lowercased() })

    /// Home-relative subtrees protected at any depth (lowercased, trailing slash).
    private static let blockedHomeRelativePrefixes: [String] = [
        "library/keychains/",
        "library/application support/com.apple.tcc/",
        ".ssh/",
        ".gnupg/"
    ]

    private static let selfLeafNames: Set<String> = ["ztat.app", "ztat-dev.app", "dev.ztat.app", "dev.ztat.app.dev"]

    /// Returns an error string if the path is forbidden for deletion; nil if safe to evaluate.
    ///
    /// Every rule is evaluated against the lexical path, the symlink-resolved path, the canonical
    /// `realpath(3)` form (which keeps `/private`), the parent-resolved path, and the
    /// `/etc` ↔ `/private/etc` style firmlink aliases, all case-insensitively (APFS default).
    public static func rejectionReason(
        for url: URL,
        extraProtectedRoots: [String] = [],
        selfBundlePath: String = Bundle.main.bundlePath
    ) -> String? {
        let standardized = url.standardizedFileURL.path
        guard !standardized.isEmpty else {
            return ZtatL10n.tr("路径为空", "Empty path")
        }

        let homes = expandedVariants(of: (NSHomeDirectory() as NSString).standardizingPath)
        let selfBundles = expandedVariants(of: (selfBundlePath as NSString).standardizingPath)
            .filter { $0.hasSuffix(".app") }
        var extraRoots = Set<String>()
        for root in extraProtectedRoots {
            let cleanRoot = (root as NSString).standardizingPath
            if !cleanRoot.isEmpty {
                extraRoots.formUnion(expandedVariants(of: cleanRoot))
            }
        }

        if selfLeafNames.contains(url.lastPathComponent.lowercased()) {
            return ZtatL10n.tr("ztat 应用及配置已受保护", "Protected ztat application asset")
        }
        for candidate in candidatePaths(for: url) {
            if let reason = violation(path: candidate, homes: homes, selfBundles: selfBundles, extraRoots: extraRoots) {
                return reason
            }
        }
        return nil
    }

    /// True for Apple-owned bundle / container identifiers such as `com.apple.Safari`,
    /// `group.com.apple.notes`, `systemgroup.com.apple.x` or `TEAMID.groups.com.apple.podcasts`.
    public static func isAppleBundleIdentifier(_ identifier: String) -> Bool {
        let id = identifier.lowercased()
        return id == "com.apple"
            || id.hasPrefix("com.apple.")
            || id.hasPrefix("group.com.apple.")
            || id.contains(".com.apple.")
    }

    /// True when `identifier` is ztat itself (release, dev build, or one of its defaults suites).
    public static func isZtatBundleIdentifier(_ identifier: String) -> Bool {
        let id = identifier.lowercased()
        guard !id.isEmpty else { return false }
        return selfIdentifiers.contains { id == $0 || id.hasPrefix($0 + ".") }
    }

    // MARK: Rule evaluation

    private static func violation(path p: String, homes: [String], selfBundles: [String], extraRoots: Set<String>) -> String? {
        if hardBlockedPaths.contains(p) {
            return ZtatL10n.tr("系统关键根目录受保护，禁止删除", "Protected system root directory")
        }
        if p.hasPrefix("/system/") {
            return ZtatL10n.tr("SIP 系统卷路径受保护", "Protected SIP /System path")
        }
        if hardBlockedPrefixes.contains(where: { p.hasPrefix($0) }) {
            return ZtatL10n.tr("系统关键目录受保护，禁止删除", "Protected system directory")
        }
        let comps = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if comps.count == 2, topLevelContainerRoots.contains(comps[0]) {
            return ZtatL10n.tr("系统顶层目录或卷根目录受保护，禁止整体删除", "Protected top-level system folder or volume root")
        }
        if comps.count == 3, comps[0] == "private", comps[1] == "var" {
            return ZtatL10n.tr("系统顶层目录受保护，禁止整体删除", "Protected top-level /private/var folder")
        }
        for home in homes {
            if p == home {
                return ZtatL10n.tr("用户主目录受保护", "Protected user home directory")
            }
            if p.hasPrefix(home + "/"), let reason = homeViolation(relative: String(p.dropFirst(home.count + 1))) {
                return reason
            }
        }
        // Protect ztat itself from accidental deletion inside its own uninstaller
        for bundle in selfBundles where p == bundle || p.hasPrefix(bundle + "/") {
            return ZtatL10n.tr("禁止卸载当前正在运行的 ztat 本体", "Cannot remove running ztat app bundle")
        }
        if let leaf = comps.last, selfLeafNames.contains(leaf) {
            return ZtatL10n.tr("ztat 应用及配置已受保护", "Protected ztat application asset")
        }
        // Protect user-configured App Scan root folders themselves
        if extraRoots.contains(p) {
            return ZtatL10n.tr("应用扫描根目录受保护", "Protected application scan root folder")
        }
        return nil
    }

    private static func homeViolation(relative rel: String) -> String? {
        if blockedHomeRelatives.contains(rel) || blockedHomeRelativePrefixes.contains(where: { rel.hasPrefix($0) }) {
            return ZtatL10n.tr("用户核心目录受保护，禁止整体删除", "Protected user Library/home root directory")
        }
        let comps = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.first == "library" else { return nil }
        // Never ~/Library itself nor any of its first-level folders (Preferences, Containers, …)
        if comps.count <= 2 {
            return ZtatL10n.tr("用户资源库一级目录受保护，禁止整体删除", "Protected first-level ~/Library folder")
        }
        if comps.count == 3 {
            if (comps[1] == "containers" || comps[1] == "group containers"), isAppleBundleIdentifier(comps[2]) {
                return ZtatL10n.tr("Apple 系统容器受保护", "Protected Apple system container")
            }
            if comps[1] == "cloudstorage" {
                return ZtatL10n.tr("云盘同步目录受保护", "Protected cloud storage folder")
            }
        }
        // ztat's own data: ~/Library/{Application Support,Caches,Logs}/ztat and any dev.ztat.app* item
        let appName = ZtatBrand.appName.lowercased()
        if ["application support", "caches", "logs"].contains(comps[1]), comps[2] == appName {
            return ZtatL10n.tr("ztat 自身数据受保护", "Protected ztat data")
        }
        let ids = selfIdentifiers
        for component in comps.dropFirst(2) where isSelfIdentifierComponent(component, ids: ids) {
            return ZtatL10n.tr("ztat 自身数据受保护", "Protected ztat data")
        }
        return nil
    }

    /// Lowercased bundle identifiers that belong to ztat.
    private static var selfIdentifiers: [String] {
        var ids: Set<String> = [ZtatBrand.bundleIdentifier.lowercased(), ZtatBrand.devBundleIdentifier.lowercased()]
        if let main = Bundle.main.bundleIdentifier?.lowercased(),
           main.split(separator: ".").count >= 3,
           !isAppleBundleIdentifier(main) {
            ids.insert(main)
        }
        return Array(ids)
    }

    /// Matches `dev.ztat.app`, `dev.ztat.app.plist`, `dev.ztat.app.dev.savedState`, `TEAM.dev.ztat.app`, …
    private static func isSelfIdentifierComponent(_ component: String, ids: [String]) -> Bool {
        ids.contains { id in
            component == id
                || component.hasPrefix(id + ".")
                || component.hasSuffix("." + id)
                || component.contains("." + id + ".")
        }
    }

    // MARK: Path normalisation

    /// Lowercased lexical, symlink-resolved, canonical and parent-resolved forms of `url`,
    /// each with its firmlink alias (`/etc` ↔ `/private/etc`, `/var`, `/tmp`).
    /// When `url` itself is a symbolic link, only the link's own location is evaluated (lexical and
    /// parent-resolved forms): trashing a link never touches its target, so the target's location is
    /// irrelevant to safety and must not cause a spurious "protected" rejection.
    private static func candidatePaths(for url: URL) -> [String] {
        let standardizedURL = url.standardizedFileURL
        let standardized = standardizedURL.path
        let itemIsSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: standardized)) != nil
        var raw: [String] = [standardized]
        if !itemIsSymlink {
            raw.append(standardizedURL.resolvingSymlinksInPath().path)
            if let real = canonicalPath(standardized) {
                raw.append(real)
            }
        }
        if standardized != "/" {
            let ns = standardized as NSString
            if let parent = canonicalPath(ns.deletingLastPathComponent) {
                raw.append((parent as NSString).appendingPathComponent(ns.lastPathComponent))
            }
        }
        var out: [String] = []
        var seen = Set<String>()
        for path in raw {
            for variant in firmlinkVariants(of: path.lowercased()) where !variant.isEmpty && seen.insert(variant).inserted {
                out.append(variant)
            }
        }
        return out
    }

    /// Lowercased lexical + canonical forms (with firmlink aliases) of a reference path.
    private static func expandedVariants(of path: String) -> [String] {
        guard !path.isEmpty else { return [] }
        var raw = [path]
        if let real = canonicalPath(path) {
            raw.append(real)
        }
        var out: [String] = []
        for item in raw {
            for variant in firmlinkVariants(of: item.lowercased()) where !out.contains(variant) {
                out.append(variant)
            }
        }
        return out
    }

    private static func firmlinkVariants(of path: String) -> [String] {
        var out = [path]
        for (short, long) in [("/etc", "/private/etc"), ("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if path == short || path.hasPrefix(short + "/") {
                out.append(long + path.dropFirst(short.count))
            } else if path == long || path.hasPrefix(long + "/") {
                out.append(short + path.dropFirst(long.count))
            }
        }
        return out
    }

    /// `realpath(3)`: resolves every symlink and returns the on-disk canonical path, or nil if missing.
    private static func canonicalPath(_ path: String) -> String? {
        guard !path.isEmpty, let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Detects whether a directory resides inside a Git working repository to prevent
    /// accidental sweeping of source repositories during broad heuristic scans.
    public static func isInsideSourceRepository(_ url: URL) -> Bool {
        var cursor = url.standardizedFileURL
        let home = (NSHomeDirectory() as NSString).standardizingPath
        var hops = 0
        while hops < 6 {
            let path = cursor.path
            if path == "/" || path == home || path == "/Applications" || path == "/Library" || path.hasPrefix(home + "/Library") {
                return false
            }
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".git").path) {
                return true
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
            hops += 1
        }
        return false
    }
}

// MARK: - Persistent Delete History Manager

@MainActor
public final class DeleteHistoryStore: ObservableObject {
    public static let shared = DeleteHistoryStore()

    @Published public private(set) var entries: [DeleteHistoryEntry] = []
    private let maxEntries = 10

    private var historyFileURL: URL {
        ZtatBrand.appSupportDirectory.appendingPathComponent("cleaner-undo-history.json")
    }

    private init() {
        load()
        pruneStaleEntries()
    }

    public func record(_ entry: DeleteHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    public func removeEntries(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    public func pruneStaleEntries() {
        let before = entries.count
        entries.removeAll { entry in
            !FileManager.default.fileExists(atPath: entry.trashBundlePath) &&
            !entry.files.contains(where: { FileManager.default.fileExists(atPath: $0.trashedPath) })
        }
        if entries.count != before {
            save()
        }
    }

    public func clearAll() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyFileURL),
              let decoded = try? JSONDecoder().decode([DeleteHistoryEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: historyFileURL, options: .atomic)
        }
    }
}

// MARK: - Safe Reversible Trash-Bundle Deletion Engine

public final class SafeDeletionEngine: @unchecked Sendable {
    public static let shared = SafeDeletionEngine()

    private init() {}

    /// `sourceModule` used for Lipo backups: restoring swaps the original binary back over the thinned copy.
    public static let lipoBackupSourceModule = "lipo-backup"

    /// Moves all specified URLs into a single timestamped Trash bundle folder (`~/.Trash/<Label>_<timestamp>/`),
    /// preserving full Undo / Restore capability and preventing Sentinel self-triggering.
    ///
    /// When `terminateBundleID` is set, the app is asked to quit first; if it is still running after the
    /// grace period, nothing is touched and every URL is reported as failed with an "app still running" reason.
    public func trashItems(
        urls: [URL],
        bundleLabel: String,
        sourceModule: String,
        protectedRoots: [String] = [],
        terminateBundleID: String? = nil,
        onLog: (@Sendable (String, Bool) -> Void)? = nil
    ) async -> SafeDeletionOutcome {
        // Pause in-process Trash Sentinel so trashing an .app doesn't re-trigger cleanup
        await MainActor.run {
            TrashSentinelMonitor.shared.suspendForInternalOperation()
        }
        defer {
            Task { @MainActor in
                TrashSentinelMonitor.shared.resumeAfterInternalOperation()
            }
        }

        // Deduplicate & collapse nested children when parent is also in list
        let deduplicated = collapseNestedURLs(urls)

        if let bid = terminateBundleID, !bid.isEmpty,
           let stillRunning = await Self.terminateAndWait(bundleIdentifier: bid) {
            let reason = Self.appStillRunningMessage(stillRunning)
            onLog?(reason, true)
            var failedItems = deduplicated.map { (path: $0.path, reason: reason) }
            if failedItems.isEmpty {
                failedItems = [(path: bid, reason: reason)]
            }
            return SafeDeletionOutcome(entry: nil, succeededCount: 0, freedBytes: 0, failedItems: failedItems)
        }

        let fm = FileManager.default
        let trashRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        let bundleFolder = newTrashBundleURL(label: bundleLabel)

        var createdBundle = false
        var trashedPairs: [TrashedFilePair] = []
        var failed: [(String, String)] = []
        var privilegedCandidates: [(src: URL, dest: URL, size: Int64)] = []
        var totalFreed: Int64 = 0

        for url in deduplicated {
            let cleanURL = url.standardizedFileURL
            if let reason = SafePathGuard.rejectionReason(for: cleanURL, extraProtectedRoots: protectedRoots) {
                failed.append((cleanURL.path, reason))
                onLog?("Blocked: \(cleanURL.path) (\(reason))", true)
                continue
            }
            guard fm.fileExists(atPath: cleanURL.path) || isSymlink(cleanURL) else {
                continue
            }
            // If item is already inside ~/.Trash (e.g. Sentinel-triggered app), keep its current location without re-moving
            if cleanURL.path.hasPrefix(trashRoot.path + "/") {
                continue
            }

            if !createdBundle {
                do {
                    try fm.createDirectory(at: bundleFolder, withIntermediateDirectories: true)
                    createdBundle = true
                } catch {
                    failed.append((cleanURL.path, error.localizedDescription))
                    continue
                }
            }

            let itemSize = Self.logicalSize(of: cleanURL)
            // Unlock immutable bit if set on user-owned files
            try? fm.setAttributes([.immutable: false], ofItemAtPath: cleanURL.path)

            let dest = uniqueDestination(in: bundleFolder, preferredName: cleanURL.lastPathComponent)
            do {
                try fm.moveItem(at: cleanURL, to: dest)
                trashedPairs.append(TrashedFilePair(originalPath: cleanURL.path, trashedPath: dest.path, sizeBytes: itemSize))
                totalFreed += itemSize
                onLog?("Trashed: \(cleanURL.path)", false)
            } catch {
                // Queue for single consolidated admin prompt if permission denied
                let nsErr = error as NSError
                if nsErr.domain == NSCocoaErrorDomain && (nsErr.code == NSFileWriteNoPermissionError || nsErr.code == 513)
                    || (nsErr.domain == NSPOSIXErrorDomain && (nsErr.code == Int(EACCES) || nsErr.code == Int(EPERM))) {
                    privilegedCandidates.append((src: cleanURL, dest: dest, size: itemSize))
                } else {
                    failed.append((cleanURL.path, error.localizedDescription))
                    onLog?("Failed: \(cleanURL.path) — \(error.localizedDescription)", true)
                }
            }
        }

        // Handle any root-owned items in ONE single macOS administrator authorization dialog
        if !privilegedCandidates.isEmpty {
            if !createdBundle {
                createdBundle = (try? fm.createDirectory(at: bundleFolder, withIntermediateDirectories: true)) != nil
            }
            // Every item is attempted independently; `st` only makes the script report that *something* failed.
            // The real per-item outcome is decided below by inspecting the filesystem, never by the exit status.
            let script = "st=0; " + privilegedCandidates.map { pair -> String in
                let srcQ = shellQuote(pair.src.path)
                let dstQ = shellQuote(pair.dest.path)
                return "/usr/bin/chflags -R nouchg \(srcQ) 2>/dev/null; /bin/mv -f \(srcQ) \(dstQ) || st=1"
            }.joined(separator: "; ") + "; exit $st"

            let (ok, errText) = runPrivilegedShell(script)
            let notMovedReason = ok
                ? ZtatL10n.tr("管理员移动未完成", "Admin move incomplete")
                : (errText ?? ZtatL10n.tr("需要管理员权限", "Administrator authorization cancelled or failed"))
            for pair in privilegedCandidates {
                let landed = fm.fileExists(atPath: pair.dest.path) || isSymlink(pair.dest)
                guard landed else {
                    failed.append((pair.src.path, notMovedReason))
                    continue
                }
                // Anything that reached the bundle is recorded so it stays restorable from Delete History.
                trashedPairs.append(TrashedFilePair(originalPath: pair.src.path, trashedPath: pair.dest.path, sizeBytes: pair.size))
                let sourceGone = !fm.fileExists(atPath: pair.src.path) && !isSymlink(pair.src)
                if sourceGone {
                    totalFreed += pair.size
                    onLog?("Trashed (admin): \(pair.src.path)", false)
                } else {
                    let reason = ZtatL10n.tr("管理员移动未完成：部分内容已存入废纸篓", "Admin move incomplete: partial copy kept in Trash")
                    failed.append((pair.src.path, reason))
                    onLog?("Partially trashed (admin): \(pair.src.path)", true)
                }
            }
            if !ok {
                onLog?("Admin trash failed: \(errText ?? "cancelled")", true)
            }
        }

        // Remove the bundle folder only if nothing at all landed in it (never recursive)
        if createdBundle && trashedPairs.isEmpty {
            Self.removeDirectoryIfEmpty(bundleFolder)
        }

        var recordedEntry: DeleteHistoryEntry? = nil
        if !trashedPairs.isEmpty {
            recordedEntry = await recordHistory(
                title: bundleLabel,
                sourceModule: sourceModule,
                bundleFolder: bundleFolder,
                files: trashedPairs,
                totalBytes: totalFreed,
                playSound: true
            )
        }

        return SafeDeletionOutcome(
            entry: recordedEntry,
            succeededCount: trashedPairs.count,
            freedBytes: totalFreed,
            failedItems: failed
        )
    }

    /// Restores a recorded Trash-bundle entry back to its original filesystem paths.
    public func restoreEntry(
        _ entry: DeleteHistoryEntry,
        onLog: (@Sendable (String, Bool) -> Void)? = nil
    ) async -> (restoredCount: Int, failed: [(path: String, reason: String)]) {
        await MainActor.run {
            TrashSentinelMonitor.shared.suspendForInternalOperation()
        }
        defer {
            Task { @MainActor in
                TrashSentinelMonitor.shared.resumeAfterInternalOperation()
            }
        }

        let fm = FileManager.default
        var restored = 0
        var failed: [(String, String)] = []
        var privilegedMoves: [(src: String, dst: String)] = []
        // Lipo backups hold the original of a binary that now exists in thinned (derived) form.
        let replacesDerivedFiles = entry.sourceModule == Self.lipoBackupSourceModule

        for pair in entry.files {
            let trashedURL = URL(fileURLWithPath: pair.trashedPath)
            guard fm.fileExists(atPath: pair.trashedPath) || isSymlink(trashedURL) else {
                failed.append((pair.originalPath, ZtatL10n.tr("废纸篓中的文件已不存在", "File no longer exists in Trash")))
                continue
            }
            let destURL = URL(fileURLWithPath: pair.originalPath)
            let parentDir = destURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            let destExists = fm.fileExists(atPath: destURL.path) || isSymlink(destURL)

            if replacesDerivedFiles, destExists,
               (try? destURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                // Swap the original binary back over the thinned copy.
                do {
                    _ = try fm.replaceItemAt(destURL, withItemAt: trashedURL, backupItemName: nil, options: [.usingNewMetadataOnly])
                    restored += 1
                    onLog?("Restored: \(destURL.path)", false)
                } catch {
                    privilegedMoves.append((src: pair.trashedPath, dst: destURL.path))
                }
                continue
            }

            let finalDest = destExists
                ? uniqueDestination(in: parentDir, preferredName: destURL.lastPathComponent)
                : destURL
            do {
                try fm.moveItem(atPath: pair.trashedPath, toPath: finalDest.path)
                restored += 1
                onLog?("Restored: \(finalDest.path)", false)
            } catch {
                privilegedMoves.append((src: pair.trashedPath, dst: finalDest.path))
            }
        }

        if !privilegedMoves.isEmpty {
            let script = "st=0; " + privilegedMoves.map { pair in
                let parentQ = shellQuote((pair.dst as NSString).deletingLastPathComponent)
                return "/bin/mkdir -p \(parentQ) && /bin/mv -f \(shellQuote(pair.src)) \(shellQuote(pair.dst)) || st=1"
            }.joined(separator: "; ") + "; exit $st"
            let (_, errText) = runPrivilegedShell(script)
            for p in privilegedMoves {
                let arrived = fm.fileExists(atPath: p.dst) || isSymlink(URL(fileURLWithPath: p.dst))
                let leftBehind = fm.fileExists(atPath: p.src) || isSymlink(URL(fileURLWithPath: p.src))
                if arrived && !leftBehind {
                    restored += 1
                    onLog?("Restored (admin): \(p.dst)", false)
                } else {
                    failed.append((p.dst, errText ?? ZtatL10n.tr("还原需要管理员权限", "Admin restore failed")))
                }
            }
        }

        // Remove empty trash bundle wrapper (never recursive)
        Self.removeDirectoryIfEmpty(URL(fileURLWithPath: entry.trashBundlePath))

        if failed.isEmpty {
            await MainActor.run {
                DeleteHistoryStore.shared.removeEntries(ids: [entry.id])
            }
        }
        return (restored, failed)
    }

    // MARK: - Helpers

    /// Asks every running instance of `bundleIdentifier` to quit, then polls until they have exited.
    /// Returns nil when nothing is running any more, or the display name of an instance that is still
    /// alive after `timeout` (e.g. it shows a "save changes?" sheet or is hung) — callers must then abort.
    @MainActor
    public static func terminateAndWait(bundleIdentifier: String, timeout: TimeInterval = 8) async -> String? {
        guard !bundleIdentifier.isEmpty, !SafePathGuard.isZtatBundleIdentifier(bundleIdentifier) else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != ownPID }
        guard !running.isEmpty else { return nil }
        for app in running {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if running.allSatisfy({ $0.isTerminated }) { return nil }
            try? await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        guard let alive = running.first(where: { !$0.isTerminated }) else { return nil }
        return alive.localizedName ?? bundleIdentifier
    }

    /// User-facing reason used when an app refuses to quit before its files are touched.
    public static func appStillRunningMessage(_ appName: String) -> String {
        ZtatL10n.tr(
            "「\(appName)」仍在运行，未做任何删除。请先退出（或强制退出）该应用后重试。",
            "\(appName) is still running, so nothing was removed. Quit (or Force Quit) it and try again."
        )
    }

    /// Location for a new timestamped Trash bundle folder (not created yet).
    func newTrashBundleURL(label: String) -> URL {
        let trashRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let bundleFolderName = "\(sanitizeBundleName(label))_\(formatter.string(from: Date()))"
        return uniqueDestination(in: trashRoot, preferredName: bundleFolderName)
    }

    /// Records a Delete History entry for files already moved into `bundleFolder`.
    @discardableResult
    func recordHistory(
        title: String,
        sourceModule: String,
        bundleFolder: URL,
        files: [TrashedFilePair],
        totalBytes: Int64,
        playSound: Bool
    ) async -> DeleteHistoryEntry {
        let entry = DeleteHistoryEntry(
            id: UUID(),
            timestamp: Date(),
            operationTitle: title,
            sourceModule: sourceModule,
            trashBundlePath: bundleFolder.path,
            files: files,
            totalBytes: totalBytes
        )
        await MainActor.run {
            DeleteHistoryStore.shared.record(entry)
            if playSound {
                Self.playTrashSound()
            }
        }
        return entry
    }

    /// Removes `folder` only if it contains nothing but Finder metadata (`rmdir` semantics, never recursive).
    @discardableResult
    static func removeDirectoryIfEmpty(_ folder: URL) -> Bool {
        let path = folder.path
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path),
              contents.allSatisfy({ $0 == ".DS_Store" }) else {
            return false
        }
        if !contents.isEmpty {
            _ = unlink((path as NSString).appendingPathComponent(".DS_Store"))
        }
        return rmdir(path) == 0
    }

    public func collapseNestedURLs(_ urls: [URL]) -> [URL] {
        let unique = Array(Set(urls.map { $0.standardizedFileURL }))
            .sorted { $0.path.count < $1.path.count }
        var kept: [URL] = []
        for candidate in unique {
            let path = candidate.path
            let covered = kept.contains { parent in
                path == parent.path || path.hasPrefix(parent.path + "/")
            }
            if !covered {
                kept.append(candidate)
            }
        }
        return kept
    }

    func uniqueDestination(in folder: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(preferredName)
        if !fm.fileExists(atPath: candidate.path) && !isSymlink(candidate) {
            return candidate
        }
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        for idx in 1...999 {
            let name = ext.isEmpty ? "\(base)-\(idx)" : "\(base)-\(idx).\(ext)"
            candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) && !isSymlink(candidate) {
                return candidate
            }
        }
        return folder.appendingPathComponent("\(preferredName)-\(UUID().uuidString.prefix(6))")
    }

    private func sanitizeBundleName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\n\r\t")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "ztat_Cleanup" : String(cleaned.prefix(64))
    }

    public func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    public static func logicalSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return 0
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
            return Int64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? vals?.fileSize ?? 0)
        }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        for case let item as URL in enumerator {
            guard let vals = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if vals.isSymbolicLink == true { continue }
            if vals.isRegularFile == true {
                total += Int64(vals.totalFileAllocatedSize ?? vals.fileAllocatedSize ?? vals.fileSize ?? 0)
            }
        }
        return total
    }

    public func runPrivilegedShell(_ shellScript: String) -> (Bool, String?) {
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        do {
            let result = try CleanerProcessRunner.run("/usr/bin/osascript", ["-e", appleScript])
            if result.succeeded {
                return (true, nil)
            }
            let errMsg = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, errMsg.isEmpty ? "Exit status \(result.status)" : errMsg)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    public func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @MainActor
    private static func playTrashSound() {
        let soundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif"
        if FileManager.default.fileExists(atPath: soundPath),
           let sound = NSSound(contentsOfFile: soundPath, byReference: true) {
            sound.play()
        }
    }
}
