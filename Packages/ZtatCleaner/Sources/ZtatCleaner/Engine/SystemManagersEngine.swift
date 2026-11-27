// SPDX-License-Identifier: GPL-3.0-or-later
// Clean-room macOS system managers using strictly public APIs & tools:
// 1. PKG / Receipts Manager (`/var/db/receipts` + `/usr/sbin/pkgutil` + `/usr/bin/lsbom`)
// 2. 18-Category Plugins & Extensions Manager + Audio related-file search
// 3. Launch Services / Daemons Manager (`launchctl` + plist discovery)
// 4. Read-only SQLite TCC Permissions Viewer (`TCC.db` across 24 kTCCService keys)

import Foundation
import SQLite3
import ZtatCore

// MARK: - 1. PKG / Receipts Manager

public final class PackageReceiptsEngine: @unchecked Sendable {
    public static let shared = PackageReceiptsEngine()

    private init() {}

    /// Bundle extensions a receipt file may be grouped under when the package owns the whole bundle.
    private static let collapsibleBundleExts: Set<String> = [
        "app", "appex", "xpc", "kext", "driver", "plugin", "bundle", "component",
        "vst", "vst3", "au", "framework", "service", "prefpane", "menu",
        "qlgenerator", "saver", "mdimporter", "action", "workflow", "xcodeproj",
        "xcworkspace", "xcframework", "dsym", "pkg", "clr"
    ]

    public func listThirdPartyReceipts() async -> [PackageReceiptItem] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let receiptsDir = URL(fileURLWithPath: "/private/var/db/receipts", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: receiptsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                return []
            }

            var items: [PackageReceiptItem] = []
            for file in files where file.pathExtension.lowercased() == "plist" {
                let pkgID = file.deletingPathExtension().lastPathComponent
                if pkgID.lowercased().hasPrefix("com.apple.") { continue }

                guard let data = try? Data(contentsOf: file),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    continue
                }

                let version = (plist["PackageVersion"] as? String) ?? "—"
                let installDate = plist["InstallDate"] as? Date
                let prefix = (plist["InstallPrefixPath"] as? String) ?? "/"
                let volume = (plist["InstallVolume"] as? String) ?? "/"
                let bomURL = receiptsDir.appendingPathComponent("\(pkgID).bom")
                let hasBom = fm.fileExists(atPath: bomURL.path)

                let prettyName = pkgID.split(separator: ".").last.map(String.init) ?? pkgID
                items.append(PackageReceiptItem(
                    id: pkgID,
                    packageID: pkgID,
                    displayName: prettyName,
                    version: version,
                    installDate: installDate,
                    installPrefix: prefix,
                    volume: volume,
                    receiptPlistURL: file,
                    receiptBomURL: hasBom ? bomURL : nil,
                    estimatedSize: 0
                ))
            }
            return items.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }.value
    }

    /// Lists the files a package installed and returns them as uninstall candidates.
    ///
    /// Receipts record every intermediate directory of the payload (`/Library/Fonts`,
    /// `/usr/local/include`, `/Library/Application Support/<Vendor>`, `/private/etc` …), and
    /// those are shared with other software. So only *files* (regular files and symlinks) are
    /// read from the receipt. Several packages can install into one bundle (for example each
    /// Python installer owns only `Python.framework/Versions/<X>`), so a bundle becomes a single
    /// entry only when every file inside it on disk is recorded by this receipt; otherwise the
    /// package's own files inside it are listed one by one.
    /// Directories are never pre-selected: a directory is only offered — unchecked — when it
    /// would be empty once this package's own files are gone. A symlink is pre-selected only
    /// when it would dangle after the uninstall (its target goes too, or is already gone).
    public func loadBOMEntries(for receipt: PackageReceiptItem) async -> [PackageBOMEntry] {
        await Task.detached(priority: .userInitiated) {
            let root = self.installRoot(for: receipt)
            let ownedFiles = Set(self.payloadPaths(for: receipt, directories: false).map {
                Self.normalized(self.absolutePath($0, root: root))
            })
            guard !ownedFiles.isEmpty else { return [] }

            let ownership = BundleOwnershipResolver(ownedFiles: ownedFiles)
            let removalUnits = Set(ownedFiles.map { ownership.removalUnit(for: $0) })
            let ownedBundles = removalUnits.filter { ownership.isOwnedBundle($0) }

            var candidates: [(url: URL, type: FileAttributeType?)] = []
            for path in removalUnits.sorted() {
                let url = URL(fileURLWithPath: path)
                if SafePathGuard.rejectionReason(for: url) != nil { continue }
                let type = Self.itemType(atPath: path)
                // The receipt says "file" but a real directory sits there now: not ours to take.
                if type == .typeDirectory && !ownedBundles.contains(path) { continue }
                candidates.append((url, type))
            }

            // Everything except symlinks that this uninstall removes, with ancestor symlinks
            // resolved so link targets can be compared against it.
            let removedRoots = Set(candidates.compactMap { candidate -> String? in
                guard let type = candidate.type, type != .typeSymbolicLink else { return nil }
                return candidate.url.resolvingSymlinksInPath().path
            })

            var ownedExistingPaths = Set<String>()
            var entries: [PackageBOMEntry] = []
            for candidate in candidates {
                let selected: Bool
                switch candidate.type {
                case nil:
                    selected = false
                case .typeSymbolicLink?:
                    selected = Self.symlinkWouldDangle(candidate.url, removedRoots: removedRoots)
                default:
                    selected = true
                }
                let exists = candidate.type != nil
                if exists { ownedExistingPaths.insert(candidate.url.path) }
                entries.append(PackageBOMEntry(
                    id: candidate.url.path,
                    url: candidate.url,
                    exists: exists,
                    size: exists ? SafeDeletionEngine.logicalSize(of: candidate.url) : 0,
                    isProtectedSystemRoot: false,
                    isSelected: selected
                ))
            }

            entries.append(contentsOf: self.emptiedDirectoryEntries(
                for: receipt,
                root: root,
                ownedExistingPaths: ownedExistingPaths,
                ownedBundles: ownedBundles
            ))

            return entries.sorted { lhs, rhs in
                if lhs.exists != rhs.exists { return lhs.exists }
                if lhs.isDirectory != rhs.isDirectory { return !lhs.isDirectory }
                return lhs.size > rhs.size
            }
        }.value
    }

    /// Payload directories that would be left empty (ignoring `.DS_Store`) once the package's
    /// own files are removed — offered unchecked, deepest first so nested empty trees qualify.
    /// Directories inside a bundle that is removed as a whole are already covered by it.
    private func emptiedDirectoryEntries(for receipt: PackageReceiptItem,
                                         root: String,
                                         ownedExistingPaths: Set<String>,
                                         ownedBundles: Set<String>) -> [PackageBOMEntry] {
        let fm = FileManager.default
        let rootPath = Self.normalized(root)
        let directories = Set(self.payloadPaths(for: receipt, directories: true).map {
            Self.normalized(self.absolutePath($0, root: root))
        })
        .filter { path in
            path != rootPath && !Self.isSelfOrDescendant(path, ofAnyOf: ownedBundles)
        }
        .sorted { ($0 as NSString).pathComponents.count > ($1 as NSString).pathComponents.count }

        var removable = Set<String>()
        var entries: [PackageBOMEntry] = []
        for path in directories {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard Self.itemType(atPath: path) == .typeDirectory,
                  SafePathGuard.rejectionReason(for: url) == nil,
                  let children = try? fm.contentsOfDirectory(atPath: path) else { continue }
            let emptyAfterUninstall = children.allSatisfy { name in
                if name == ".DS_Store" { return true }
                let child = (path as NSString).appendingPathComponent(name)
                return ownedExistingPaths.contains(child) || removable.contains(child)
            }
            guard emptyAfterUninstall else { continue }
            removable.insert(path)
            entries.append(PackageBOMEntry(
                id: path,
                url: url,
                exists: true,
                size: 0,
                isProtectedSystemRoot: false,
                isSelected: false,
                isDirectory: true
            ))
        }
        return entries
    }

    /// Decides whether a receipt file is removed on its own or as part of an enclosing bundle.
    /// A bundle qualifies only when every non-directory item inside it on disk (symlinks
    /// included, not followed) is recorded by the receipt.
    private final class BundleOwnershipResolver {
        /// Bundles with more items than this are never treated as provably owned.
        private static let enumerationCap = 5_000

        private let ownedFiles: Set<String>
        private var cache: [String: Bool] = [:]

        init(ownedFiles: Set<String>) {
            self.ownedFiles = ownedFiles
        }

        /// The outermost fully owned bundle containing `file`, or `file` itself.
        func removalUnit(for file: String) -> String {
            for bundle in Self.candidateBundles(for: file) where isFullyOwned(bundle) {
                return bundle
            }
            return file
        }

        func isOwnedBundle(_ path: String) -> Bool {
            cache[path] == true
        }

        /// Bundle ancestors of `file`, outermost first. Inside a framework its
        /// `Versions/<X>` directory is a candidate too, since packages often share the
        /// framework while each owns one version.
        private static func candidateBundles(for file: String) -> [String] {
            let components = (file as NSString).pathComponents
            guard components.count > 2 else { return [] }
            var result: [String] = []
            var accumulated = ""
            for index in 0..<(components.count - 1) {      // ancestors only, never the file
                let component = components[index]
                accumulated = index == 0 ? component : (accumulated as NSString).appendingPathComponent(component)
                let ext = (component as NSString).pathExtension.lowercased()
                guard PackageReceiptsEngine.collapsibleBundleExts.contains(ext) else { continue }
                result.append(accumulated)
                if ext == "framework",
                   index + 2 < components.count - 1,
                   components[index + 1] == "Versions" {
                    let versions = (accumulated as NSString).appendingPathComponent("Versions")
                    result.append((versions as NSString).appendingPathComponent(components[index + 2]))
                }
            }
            return result
        }

        private func isFullyOwned(_ bundle: String) -> Bool {
            if let cached = cache[bundle] { return cached }
            let owned = computeFullOwnership(of: bundle)
            cache[bundle] = owned
            return owned
        }

        private func computeFullOwnership(of bundle: String) -> Bool {
            guard PackageReceiptsEngine.itemType(atPath: bundle) == .typeDirectory else { return false }
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            var enumerationFailed = false
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: bundle, isDirectory: true),
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, _ in
                    enumerationFailed = true    // unreadable content cannot be proven ours
                    return false
                }
            ) else { return false }

            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited > Self.enumerationCap { return false }
                let values = try? url.resourceValues(forKeys: keys)
                if values?.isDirectory == true && values?.isSymbolicLink != true { continue }
                if url.lastPathComponent == ".DS_Store" { continue }
                if !ownedFiles.contains(PackageReceiptsEngine.normalized(url.path)) { return false }
            }
            return !enumerationFailed
        }
    }

    /// Whether removing everything in `removedRoots` leaves this symlink pointing nowhere.
    private static func symlinkWouldDangle(_ link: URL, removedRoots: Set<String>) -> Bool {
        let fm = FileManager.default
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return false }
        let target = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : link.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(destination)
        // Already broken (fileExists follows the whole link chain).
        guard fm.fileExists(atPath: target.path) else { return true }
        var path = target.resolvingSymlinksInPath().path
        while !path.isEmpty && path != "/" {
            if removedRoots.contains(path) { return true }
            path = (path as NSString).deletingLastPathComponent
        }
        return false
    }

    private static func isSelfOrDescendant(_ path: String, ofAnyOf ancestors: Set<String>) -> Bool {
        guard !ancestors.isEmpty else { return false }
        var current = path
        while !current.isEmpty && current != "/" {
            if ancestors.contains(current) { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Paths recorded by the receipt, relative to its install location — files (and symlinks)
    /// or directories only. Uses `pkgutil`, falling back to reading the receipt BOM directly.
    private func payloadPaths(for receipt: PackageReceiptItem, directories: Bool) -> [String] {
        var args = [directories ? "--only-dirs" : "--only-files", "--files", receipt.packageID]
        if !receipt.volume.isEmpty && receipt.volume != "/" {
            args.insert(contentsOf: ["--volume", receipt.volume], at: 0)
        }
        if let result = try? CleanerProcessRunner.run("/usr/sbin/pkgutil", args), result.succeeded {
            let paths = Self.relativePaths(in: result.stdoutString)
            if !paths.isEmpty { return paths }
        }
        guard let bomURL = receipt.receiptBomURL else { return [] }
        let typeFilter = directories ? ["-d"] : ["-f", "-l"]
        guard let result = try? CleanerProcessRunner.run("/usr/bin/lsbom", typeFilter + ["-p", "f", bomURL.path]),
              result.succeeded else { return [] }
        return Self.relativePaths(in: result.stdoutString)
    }

    private static func relativePaths(in output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            var rel = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if rel.hasPrefix("./") { rel = String(rel.dropFirst(2)) }
            return (rel.isEmpty || rel == ".") ? nil : rel
        }
    }

    /// Install volume + install-location recorded in the receipt.
    private func installRoot(for receipt: PackageReceiptItem) -> String {
        let volume = receipt.volume.isEmpty ? "/" : receipt.volume
        let prefix = receipt.installPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return prefix.isEmpty ? volume : (volume as NSString).appendingPathComponent(prefix)
    }

    private func absolutePath(_ relative: String, root: String) -> String {
        (root as NSString).appendingPathComponent(relative)
    }

    /// File type without following a trailing symlink; `nil` when nothing exists at `path`.
    private static func itemType(atPath path: String) -> FileAttributeType? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.type] as? FileAttributeType
    }

    /// Checks whether any `.app` referenced by this receipt is still installed in `/Applications` or `~/Applications`.
    public func activeAppsBlockingForget(bomEntries: [PackageBOMEntry]) -> [URL] {
        let fm = FileManager.default
        let homeApps = (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        return bomEntries.compactMap { entry in
            guard entry.exists, entry.url.pathExtension.lowercased() == "app" else { return nil }
            let path = entry.url.path
            if (path.hasPrefix("/Applications/") || path.hasPrefix(homeApps + "/")) && fm.fileExists(atPath: path) {
                return entry.url
            }
            return nil
        }
    }

    /// Forgets a package receipt by moving its `.plist` and `.bom` files to Trash bundle (and invoking `pkgutil --forget`).
    public func forgetReceipt(_ receipt: PackageReceiptItem) async -> (Bool, String?) {
        var urls: [URL] = []
        if let p = receipt.receiptPlistURL { urls.append(p) }
        if let b = receipt.receiptBomURL { urls.append(b) }
        let outcome = await SafeDeletionEngine.shared.trashItems(
            urls: urls,
            bundleLabel: "PKG_Receipt_\(receipt.displayName)",
            sourceModule: "packages"
        )
        if outcome.failedItems.isEmpty {
            return (true, nil)
        }
        return (false, outcome.failedItems.first?.reason)
    }
}

// MARK: - 2. 18-Category Plugins Manager

public final class PluginsScannerEngine: @unchecked Sendable {
    public static let shared = PluginsScannerEngine()

    private init() {}

    private struct PluginScanSpec {
        let category: PluginCategory
        let directories: [String]
        let extensions: Set<String>? // nil == any non-hidden item
    }

    private static func scanSpecs(home: String) -> [PluginScanSpec] {
        [
            PluginScanSpec(category: .audio, directories: [
                "\(home)/Library/Audio/Plug-Ins/Components",
                "/Library/Audio/Plug-Ins/Components",
                "\(home)/Library/Audio/Plug-Ins/HAL",
                "/Library/Audio/Plug-Ins/HAL",
                "\(home)/Library/Audio/Plug-Ins/VST",
                "/Library/Audio/Plug-Ins/VST",
                "\(home)/Library/Audio/Plug-Ins/VST3",
                "/Library/Audio/Plug-Ins/VST3",
                "\(home)/Library/Audio/Plug-Ins/CLAP",
                "/Library/Audio/Plug-Ins/CLAP",
                "\(home)/Library/Audio/Plug-Ins/MAS",
                "/Library/Application Support/Avid/Audio/Plug-Ins"
            ], extensions: nil),
            PluginScanSpec(category: .preferencePanes, directories: ["/Library/PreferencePanes", "\(home)/Library/PreferencePanes"], extensions: ["prefpane"]),
            PluginScanSpec(category: .quickLook, directories: ["/Library/QuickLook", "\(home)/Library/QuickLook"], extensions: ["qlgenerator"]),
            PluginScanSpec(category: .screenSavers, directories: ["/Library/Screen Savers", "\(home)/Library/Screen Savers"], extensions: ["saver"]),
            PluginScanSpec(category: .internetPlugIns, directories: ["/Library/Internet Plug-Ins", "\(home)/Library/Internet Plug-Ins"], extensions: ["plugin", "webplugin"]),
            PluginScanSpec(category: .coreImage, directories: ["/Library/CoreImage", "\(home)/Library/CoreImage"], extensions: ["plugin"]),
            PluginScanSpec(category: .colorPickers, directories: ["/Library/ColorPickers", "\(home)/Library/ColorPickers"], extensions: ["colorpicker"]),
            PluginScanSpec(category: .fonts, directories: ["\(home)/Library/Fonts"], extensions: ["ttf", "otf", "dfont", "ttc"]),
            PluginScanSpec(category: .dictionaries, directories: ["/Library/Dictionaries", "\(home)/Library/Dictionaries"], extensions: ["dictionary"]),
            PluginScanSpec(category: .automator, directories: ["/Library/Automator", "\(home)/Library/Automator"], extensions: ["action", "workflow"]),
            PluginScanSpec(category: .safariExtensions, directories: ["/Library/Safari/Extensions", "\(home)/Library/Safari/Extensions"], extensions: ["safariextz", "appex"]),
            PluginScanSpec(category: .motionTemplates, directories: ["\(home)/Movies/Motion Templates", "/Library/Application Support/Final Cut Pro System Support/Plug-ins"], extensions: nil),
            PluginScanSpec(category: .spotlight, directories: ["/Library/Spotlight", "\(home)/Library/Spotlight"], extensions: ["mdimporter"]),
            PluginScanSpec(category: .services, directories: ["/Library/Services", "\(home)/Library/Services"], extensions: ["service"]),
            PluginScanSpec(category: .addressBook, directories: ["\(home)/Library/Address Book Plug-Ins"], extensions: nil),
            PluginScanSpec(category: .contextualMenu, directories: ["/Library/Contextual Menu Items", "\(home)/Library/Contextual Menu Items"], extensions: nil),
            PluginScanSpec(category: .inputMethods, directories: ["/Library/Input Methods", "\(home)/Library/Input Methods"], extensions: nil),
            PluginScanSpec(category: .widgets, directories: ["/Library/Widgets", "\(home)/Library/Widgets"], extensions: ["wdgt", "appex"])
        ]
    }

    public func scanPlugins() async -> [PluginItem] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let home = (NSHomeDirectory() as NSString).standardizingPath
            var items: [PluginItem] = []
            var seen = Set<String>()

            for spec in Self.scanSpecs(home: home) {
                if Task.isCancelled { break }
                for dirPath in spec.directories {
                    let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)
                    guard let children = try? fm.contentsOfDirectory(
                        at: dirURL,
                        includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    for child in children {
                        let clean = child.standardizedFileURL
                        guard seen.insert(clean.path).inserted else { continue }
                        let name = clean.lastPathComponent
                        if name.hasPrefix(".") || name.hasPrefix("~") { continue }
                        if let allowed = spec.extensions, !allowed.contains(clean.pathExtension.lowercased()) {
                            continue
                        }
                        let rv = try? clean.resourceValues(forKeys: [.contentModificationDateKey])
                        let bid = Bundle(url: clean)?.bundleIdentifier
                        let size = SafeDeletionEngine.logicalSize(of: clean)
                        items.append(PluginItem(
                            id: clean.path,
                            url: clean,
                            name: name,
                            category: spec.category,
                            bundleIdentifier: bid,
                            isSystemDomain: !clean.path.hasPrefix(home + "/"),
                            size: size,
                            modifiedDate: rv?.contentModificationDate,
                            isSelected: false
                        ))
                    }
                }
            }
            return items.sorted { lhs, rhs in
                if lhs.category != rhs.category {
                    return lhs.category.title < rhs.category.title
                }
                return lhs.size > rhs.size
            }
        }.value
    }

    /// Finds presets/support/caches items that belong to an audio plugin.
    ///
    /// Matches are exact with a dot boundary only — an item named after the plugin
    /// (`Name`, `Name.plist`, `Name.savedState`) or its bundle ID (`com.vendor.plugin`,
    /// `com.vendor.plugin.plist`) — never a substring. Hits are suggestions: the caller must
    /// let the user opt in to each one.
    public func findRelatedFiles(for plugin: PluginItem) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let home = NSHomeDirectory()
            let name = plugin.url.deletingPathExtension().lastPathComponent.lowercased()
            let bid = (plugin.bundleIdentifier ?? "").lowercased()
            let keys = [bid, name].filter { $0.count >= 3 }
            guard !keys.isEmpty else { return [] }

            let dirs = [
                "\(home)/Library/Application Support",
                "/Library/Application Support",
                "\(home)/Library/Audio/Presets",
                "/Library/Audio/Presets",
                "\(home)/Library/Preferences",
                "\(home)/Library/Caches"
            ]
            let pluginPath = plugin.url.standardizedFileURL.path
            var hits: [URL] = []
            var seen = Set<String>()
            for d in dirs {
                let u = URL(fileURLWithPath: d, isDirectory: true)
                guard let children = try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for child in children {
                    let clean = child.standardizedFileURL
                    if clean.path == pluginPath { continue }
                    let lower = clean.lastPathComponent.lowercased()
                    let matches = keys.contains { key in lower == key || lower.hasPrefix(key + ".") }
                    guard matches,
                          SafePathGuard.rejectionReason(for: clean) == nil,
                          seen.insert(clean.path).inserted else { continue }
                    hits.append(clean)
                }
            }
            return hits
        }.value
    }
}

// MARK: - 3. Launch Services / Daemons Manager

public final class LaunchServicesEngine: @unchecked Sendable {
    public static let shared = LaunchServicesEngine()

    private init() {}

    public func scanServices() async -> [LaunchServiceItem] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let home = NSHomeDirectory()
            let runtimeMap = self.parseLaunchctlList()
            var byLabel: [String: LaunchServiceItem] = [:]

            let dirs: [(path: String, kind: LaunchServiceKind)] = [
                ("\(home)/Library/LaunchAgents", .userAgent),
                ("/Library/LaunchAgents", .globalAgent),
                ("/Library/LaunchDaemons", .globalDaemon)
            ]

            for entry in dirs {
                let dirURL = URL(fileURLWithPath: entry.path, isDirectory: true)
                guard let files = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                    continue
                }
                for file in files where file.pathExtension.lowercased() == "plist" {
                    guard let data = try? Data(contentsOf: file),
                          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                        continue
                    }
                    let label = (plist["Label"] as? String) ?? file.deletingPathExtension().lastPathComponent
                    if Self.isExcludedSystemLabel(label) { continue }
                    let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                    let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
                    let rt = entry.kind == .globalDaemon ? self.systemDomainState(label: label) : runtimeMap[label]
                    byLabel[label] = LaunchServiceItem(
                        id: "\(entry.kind.rawValue):\(label)",
                        label: label,
                        kind: entry.kind,
                        plistURL: file.standardizedFileURL,
                        associatedAppURL: nil,
                        programPath: program,
                        pid: rt?.pid,
                        lastExitStatus: rt?.status,
                        isLoaded: rt != nil,
                        runAtLoad: runAtLoad
                    )
                }
            }

            // Embedded LaunchAgents / LaunchDaemons / XPCServices inside installed apps
            let appRoots = ["/Applications", "\(home)/Applications"]
            for appRoot in appRoots {
                let rootURL = URL(fileURLWithPath: appRoot, isDirectory: true)
                guard let apps = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for app in apps where app.pathExtension.lowercased() == "app" {
                    let subdirs: [(rel: String, kind: LaunchServiceKind)] = [
                        ("Contents/Library/LaunchAgents", .embeddedHelper),
                        ("Contents/Library/LaunchDaemons", .embeddedHelper),
                        ("Contents/XPCServices", .xpcService)
                    ]
                    for sub in subdirs {
                        let subURL = app.appendingPathComponent(sub.rel, isDirectory: true)
                        guard let entries = try? fm.contentsOfDirectory(at: subURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                        for item in entries {
                            if sub.kind == .xpcService && item.pathExtension.lowercased() == "xpc" {
                                let label = Bundle(url: item)?.bundleIdentifier ?? item.deletingPathExtension().lastPathComponent
                                if Self.isExcludedSystemLabel(label) || byLabel[label] != nil { continue }
                                let rt = runtimeMap[label]
                                byLabel[label] = LaunchServiceItem(
                                    id: "xpc:\(label)",
                                    label: label,
                                    kind: .xpcService,
                                    plistURL: item.appendingPathComponent("Contents/Info.plist"),
                                    associatedAppURL: app,
                                    programPath: item.path,
                                    pid: rt?.pid,
                                    lastExitStatus: rt?.status,
                                    isLoaded: rt != nil,
                                    runAtLoad: false
                                )
                            } else if item.pathExtension.lowercased() == "plist" {
                                guard let data = try? Data(contentsOf: item),
                                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { continue }
                                let label = (plist["Label"] as? String) ?? item.deletingPathExtension().lastPathComponent
                                if Self.isExcludedSystemLabel(label) || byLabel[label] != nil { continue }
                                let rt = sub.rel.hasSuffix("LaunchDaemons")
                                    ? self.systemDomainState(label: label)
                                    : runtimeMap[label]
                                byLabel[label] = LaunchServiceItem(
                                    id: "embedded:\(label)",
                                    label: label,
                                    kind: .embeddedHelper,
                                    plistURL: item.standardizedFileURL,
                                    associatedAppURL: app,
                                    programPath: (plist["ProgramArguments"] as? [String])?.first,
                                    pid: rt?.pid,
                                    lastExitStatus: rt?.status,
                                    isLoaded: rt != nil,
                                    runAtLoad: (plist["RunAtLoad"] as? Bool) ?? false
                                )
                            }
                        }
                    }
                }
            }

            // Runtime-only third-party launchd jobs not backed by a scanned plist
            for (label, rt) in runtimeMap {
                if Self.isExcludedSystemLabel(label) || byLabel[label] != nil { continue }
                byLabel[label] = LaunchServiceItem(
                    id: "runtime:\(label)",
                    label: label,
                    kind: .runtimeOnly,
                    plistURL: nil,
                    associatedAppURL: nil,
                    programPath: nil,
                    pid: rt.pid,
                    lastExitStatus: rt.status,
                    isLoaded: true,
                    runAtLoad: false
                )
            }

            return byLabel.values.sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                if lhs.isLoaded != rhs.isLoaded { return lhs.isLoaded }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
        }.value
    }

    public enum ServiceAction: String, Sendable {
        case start
        case stop
        case restart
        case remove
    }

    /// Runs a launchd action against the job's real domain: `system` for LaunchDaemons (as
    /// root), `gui/<uid>` for user and global LaunchAgents (no elevation — agents in
    /// `/Library/LaunchAgents` run per user, not as root).
    ///
    /// - start:   bootstrap the plist if it isn't loaded yet, then `kickstart` the job.
    /// - stop:    `bootout` the job; succeeds when the job is no longer present in its domain.
    /// - restart: `kickstart -k`.
    /// - remove:  stop, then `disable` so launchd doesn't load it again at login/boot.
    public func perform(_ action: ServiceAction, on service: LaunchServiceItem) async -> (Bool, String) {
        await Task.detached(priority: .userInitiated) {
            let target = service.launchdServiceTarget

            // Nothing to stop: skip the work (and an admin prompt for system daemons).
            if action == .stop, !service.isLoaded, !self.isJobPresent(target) {
                return (true, ZtatL10n.tr("服务未加载", "Service is not loaded"))
            }

            let quote = SafeDeletionEngine.shared.shellQuote
            let launchctl = "/bin/launchctl"
            let qTarget = quote(target)
            let bootoutUntilGone = "\(launchctl) bootout \(qTarget) || ! \(launchctl) print \(qTarget) >/dev/null 2>&1"

            let script: String
            switch action {
            case .start:
                if let plist = service.plistURL, !service.isLoaded, service.kind != .xpcService {
                    let qDomain = quote(service.launchdDomain)
                    script = "\(launchctl) enable \(qTarget) 2>/dev/null; "
                        + "\(launchctl) bootstrap \(qDomain) \(quote(plist.path)) 2>/dev/null; "
                        + "\(launchctl) kickstart \(qTarget)"
                } else {
                    script = "\(launchctl) kickstart \(qTarget)"
                }
            case .stop:
                script = bootoutUntilGone
            case .restart:
                script = "\(launchctl) kickstart -k \(qTarget)"
            case .remove:
                script = "( \(bootoutUntilGone) ) && \(launchctl) disable \(qTarget)"
            }

            if service.requiresElevation {
                let (ok, err) = SafeDeletionEngine.shared.runPrivilegedShell(script)
                return (ok, err ?? (ok ? "OK" : "Failed"))
            }

            do {
                let result = try CleanerProcessRunner.run("/bin/sh", ["-c", script])
                let text = result.combinedTrimmed
                if result.succeeded { return (true, text.isEmpty ? "OK" : text) }
                return (false, text.isEmpty ? "launchctl exit \(result.status)" : text)
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }

    /// `launchctl print <domain>/<label>` exits 0 only while the job is loaded in that domain.
    private func isJobPresent(_ serviceTarget: String) -> Bool {
        (try? CleanerProcessRunner.run("/bin/launchctl", ["print", serviceTarget]))?.succeeded ?? false
    }

    /// `launchctl list` run as the user only sees the user's own domains, so system daemons
    /// would never show as loaded. Query each one with `launchctl print system/<label>`.
    private func systemDomainState(label: String) -> (pid: Int32?, status: Int32?)? {
        guard let result = try? CleanerProcessRunner.run("/bin/launchctl", ["print", "system/\(label)"]),
              result.succeeded else { return nil }
        var pid: Int32?
        var status: Int32?
        for raw in result.stdoutString.split(separator: "\n") {
            // Top-level properties are indented by exactly one tab; nested sections by more.
            guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t") else { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if pid == nil, line.hasPrefix("pid = ") {
                pid = Int32(line.dropFirst("pid = ".count))
            } else if status == nil, line.hasPrefix("last exit code = ") {
                status = Int32(line.dropFirst("last exit code = ".count))
            }
        }
        return (pid, status)
    }

    private func parseLaunchctlList() -> [String: (pid: Int32?, status: Int32?)] {
        guard let result = try? CleanerProcessRunner.run("/bin/launchctl", ["list"]),
              result.succeeded else { return [:] }
        let out = result.stdoutString
        var map: [String: (Int32?, Int32?)] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t")
            guard parts.count >= 3 else { continue }
            let pid = Int32(parts[0])
            let status = Int32(parts[1])
            let label = String(parts[2])
            map[label] = (pid, status)
        }
        return map
    }

    private static func isExcludedSystemLabel(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.hasPrefix("com.apple.")
            || lower.hasPrefix("application.com.apple.")
            || lower.hasPrefix("application.")
            || lower.hasPrefix("dev.ztat.")
            || lower.hasPrefix("[0x")
    }
}

// MARK: - 4. Read-Only SQLite TCC Permissions Viewer

public final class TCCPermissionsEngine: @unchecked Sendable {
    public static let shared = TCCPermissionsEngine()

    private init() {}

    private static let serviceNames: [String: (zh: String, en: String)] = [
        "kTCCServiceSystemPolicyAllFiles": ("完全磁盘访问权限", "Full Disk Access"),
        "kTCCServiceSystemPolicyAppBundles": ("App 管理", "App Management"),
        "kTCCServiceSystemPolicyDesktopFolder": ("桌面文件夹", "Desktop Folder"),
        "kTCCServiceSystemPolicyDocumentsFolder": ("文稿文件夹", "Documents Folder"),
        "kTCCServiceSystemPolicyDownloadsFolder": ("下载文件夹", "Downloads Folder"),
        "kTCCServiceSystemPolicyNetworkVolumes": ("网络宗卷", "Network Volumes"),
        "kTCCServiceSystemPolicyRemovableVolumes": ("可移动宗卷", "Removable Volumes"),
        "kTCCServiceAccessibility": ("辅助功能", "Accessibility"),
        "kTCCServiceListenEvent": ("输入监控", "Input Monitoring"),
        "kTCCServicePostEvent": ("事件发送", "Post Events"),
        "kTCCServiceEndpointSecurityClient": ("端点安全", "Endpoint Security"),
        "kTCCServiceScreenCapture": ("录屏与系统录音", "Screen Recording"),
        "kTCCServiceAudioCapture": ("系统音频录制", "System Audio Recording"),
        "kTCCServiceCamera": ("相机", "Camera"),
        "kTCCServiceMicrophone": ("麦克风", "Microphone"),
        "kTCCServiceLocation": ("定位服务", "Location"),
        "kTCCServiceAddressBook": ("通讯录", "Contacts"),
        "kTCCServiceCalendar": ("日历", "Calendars"),
        "kTCCServiceReminders": ("提醒事项", "Reminders"),
        "kTCCServicePhotos": ("照片", "Photos"),
        "kTCCServiceMediaLibrary": ("媒体与 Apple Music", "Media & Apple Music"),
        "kTCCServiceBluetoothAlways": ("蓝牙", "Bluetooth"),
        "kTCCServiceWillow": ("家庭 (HomeKit)", "Home"),
        "kTCCServiceAppleEvents": ("自动化 (AppleEvents)", "Automation"),
        "kTCCServiceFileProviderPresence": ("文件提供程序", "File Provider")
    ]

    public func hasFullDiskAccess() -> Bool {
        let sysTCC = "/Library/Application Support/com.apple.TCC/TCC.db"
        return FileManager.default.isReadableFile(atPath: sysTCC)
    }

    public func queryPermissions(forBundleID bundleID: String) async -> [TCCPermissionRecord] {
        await Task.detached(priority: .userInitiated) {
            guard !bundleID.isEmpty else { return [] }
            let home = NSHomeDirectory()
            let sources: [(path: String, scope: String)] = [
                ("\(home)/Library/Application Support/com.apple.TCC/TCC.db", ZtatL10n.tr("用户", "User")),
                ("/Library/Application Support/com.apple.TCC/TCC.db", ZtatL10n.tr("系统", "System"))
            ]
            var records: [TCCPermissionRecord] = []
            for src in sources {
                records.append(contentsOf: self.readDatabase(at: src.path, scope: src.scope, bundleID: bundleID))
            }
            return records.sorted { lhs, rhs in
                if lhs.isAllowed != rhs.isAllowed { return lhs.isAllowed }
                return lhs.serviceName < rhs.serviceName
            }
        }.value
    }

    private func readDatabase(at path: String, scope: String, bundleID: String) -> [TCCPermissionRecord] {
        guard FileManager.default.isReadableFile(atPath: path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT service, auth_value, auth_reason, last_modified FROM access WHERE client_type = 0 AND client = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, bundleID, -1, transient)

        var out: [TCCPermissionRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cService = sqlite3_column_text(stmt, 0) else { continue }
            let serviceKey = String(cString: cService)
            let authValue = Int(sqlite3_column_int(stmt, 1))
            let authReason = Int(sqlite3_column_int(stmt, 2))
            let lastModEpoch = sqlite3_column_int64(stmt, 3)

            let friendly: String
            if let pair = Self.serviceNames[serviceKey] {
                friendly = ZtatL10n.tr(pair.zh, pair.en)
            } else {
                friendly = serviceKey.replacingOccurrences(of: "kTCCService", with: "")
            }

            let (statusLabel, allowed) = Self.describeAuthValue(authValue)
            let reasonLabel = Self.describeAuthReason(authReason)
            let date = lastModEpoch > 0 ? Date(timeIntervalSince1970: TimeInterval(lastModEpoch)) : nil

            out.append(TCCPermissionRecord(
                id: "\(scope):\(serviceKey)",
                serviceKey: serviceKey,
                serviceName: friendly,
                scope: scope,
                statusLabel: statusLabel,
                isAllowed: allowed,
                reasonLabel: reasonLabel,
                lastModified: date
            ))
        }
        return out
    }

    private static func describeAuthValue(_ val: Int) -> (String, Bool) {
        switch val {
        case 0: return (ZtatL10n.tr("已拒绝", "Denied"), false)
        case 1: return (ZtatL10n.tr("未知", "Unknown"), false)
        case 2: return (ZtatL10n.tr("已允许", "Allowed"), true)
        case 3: return (ZtatL10n.tr("受限允许", "Limited"), true)
        default: return ("Code \(val)", val > 1)
        }
    }

    private static func describeAuthReason(_ reason: Int) -> String {
        switch reason {
        case 1: return ZtatL10n.tr("系统错误/默认", "Error / Default")
        case 2: return ZtatL10n.tr("用户授权", "User Consent")
        case 3: return ZtatL10n.tr("用户手动设置", "User Set")
        case 4: return ZtatL10n.tr("系统策略", "System Set")
        case 5: return ZtatL10n.tr("服务策略", "Service Policy")
        case 6: return "MDM Policy"
        default: return "Reason #\(reason)"
        }
    }
}
