// SPDX-License-Identifier: GPL-3.0-or-later
// Clean-room System Data probes covering APFS snapshots, simulators, Xcode,
// package managers, AI models, Docker, VMs, IDE caches, logs, temp files,
// iOS backups, project build artifacts, system-reserved visibility, and
// claim-aware large-folder discovery.

import Darwin
import Foundation
import ZtatCore

public struct SystemDataScanContext: Sendable {
    public let home: String
    public let includeExternalVolumes: Bool

    public init(home: String = (NSHomeDirectory() as NSString).standardizingPath,
                includeExternalVolumes: Bool = false) {
        self.home = home
        self.includeExternalVolumes = includeExternalVolumes
    }

    public func homeURL(_ relative: String) -> URL {
        URL(fileURLWithPath: (home as NSString).appendingPathComponent(relative))
    }
}

public struct SystemDataProbeOutput: Sendable {
    public let probeID: String
    public let items: [SystemDataItem]
    public let claimedPaths: Set<String>

    public init(probeID: String, items: [SystemDataItem], claimedPaths: Set<String> = []) {
        self.probeID = probeID
        self.items = items
        self.claimedPaths = claimedPaths
    }
}

public enum SystemDataProbes {
    public struct ProbeSpec: Sendable {
        public let id: String
        public let label: String
        public let run: @Sendable (SystemDataScanContext) async -> SystemDataProbeOutput
    }

    public static var primaryProbes: [ProbeSpec] {
        [
            ProbeSpec(id: "snapshots", label: ZtatL10n.tr("本地时间机器快照", "APFS Snapshots"), run: { await scanSnapshots($0) }),
            ProbeSpec(id: "simulators", label: ZtatL10n.tr("模拟器与运行时", "Simulators"), run: { await scanSimulators($0) }),
            ProbeSpec(id: "xcode", label: ZtatL10n.tr("Xcode 编译产物", "Xcode"), run: { await scanXcode($0) }),
            ProbeSpec(id: "packages", label: ZtatL10n.tr("包管理器缓存", "Package Caches"), run: { await scanPackages($0) }),
            ProbeSpec(id: "aiModels", label: ZtatL10n.tr("AI 模型与权重", "AI Models"), run: { await scanAIModels($0) }),
            ProbeSpec(id: "docker", label: ZtatL10n.tr("Docker 容器与镜像", "Docker"), run: { await scanDocker($0) }),
            ProbeSpec(id: "virtualMachines", label: ZtatL10n.tr("虚拟机镜像", "Virtual Machines"), run: { await scanVirtualMachines($0) }),
            ProbeSpec(id: "devTools", label: ZtatL10n.tr("开发工具与 IDE", "Dev Tools & IDEs"), run: { await scanDevTools($0) }),
            ProbeSpec(id: "logs", label: ZtatL10n.tr("系统与应用日志", "Logs"), run: { await scanLogs($0) }),
            ProbeSpec(id: "temporary", label: ZtatL10n.tr("陈旧临时文件", "Stale Temp"), run: { await scanTemporary($0) }),
            ProbeSpec(id: "deviceBackups", label: ZtatL10n.tr("iOS 设备备份", "iOS Backups"), run: { await scanDeviceBackups($0) }),
            ProbeSpec(id: "sharedData", label: ZtatL10n.tr("共享目录", "Shared Data"), run: { await scanSharedData($0) }),
            ProbeSpec(id: "projects", label: ZtatL10n.tr("项目构建产物", "Project Artifacts"), run: { await scanProjects($0) }),
            ProbeSpec(id: "systemReserved", label: ZtatL10n.tr("系统保留与云同步", "System Reserved"), run: { await scanSystemReserved($0) })
        ]
    }

    // MARK: - Helpers

    private static let minNormalBytes: Int64 = 10 * 1_048_576      // 10 MB
    private static let minCacheBytes: Int64 = 50 * 1_048_576       // 50 MB
    private static let minCatchAllBytes: Int64 = 150 * 1_048_576   // 150 MB

    private static func claim(_ url: URL, into set: inout Set<String>) {
        set.insert(url.standardizedFileURL.path.lowercased())
        set.insert(SystemDataDiskWalker.canonicalPath(url).lowercased())
    }

    private static func isClaimed(_ url: URL, in claimed: Set<String>) -> Bool {
        let std = url.standardizedFileURL.path.lowercased()
        let canon = SystemDataDiskWalker.canonicalPath(url).lowercased()
        if claimed.contains(std) || claimed.contains(canon) { return true }
        for path in claimed {
            if std.hasPrefix(path + "/") || canon.hasPrefix(path + "/") {
                return true
            }
        }
        return false
    }

    private static func hasActiveXcodeToolchain() async -> Bool {
        guard let out = try? await CleanerProcessRunner.runAsync("/usr/bin/xcode-select", ["-p"], timeout: 4),
              out.succeeded else {
            return false
        }
        let devDir = out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return !devDir.isEmpty && FileManager.default.fileExists(atPath: devDir)
    }

    private static func isProcessRunning(exactName: String) async -> Bool {
        guard let out = try? await CleanerProcessRunner.runAsync("/usr/bin/pgrep", ["-x", exactName], timeout: 3) else {
            return false
        }
        return out.succeeded && !out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func measureFolderItem(
        id: String,
        category: SystemDataCategory,
        title: String,
        subtitle: String,
        url: URL,
        minBytes: Int64 = minNormalBytes,
        safety: SystemDataSafety,
        recovery: SystemDataRecovery,
        projectRoot: URL? = nil,
        isCompressible: Bool = false,
        detailNote: String? = nil,
        forceManual: Bool = false,
        manualGuidance: String? = nil
    ) async -> SystemDataItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let m = await SystemDataDiskWalker.measure(url: url, timeoutSeconds: 20)
        guard m.bytes >= minBytes else { return nil }

        let guardReason = SafePathGuard.rejectionReason(for: url)
        let effectiveAction: SystemDataAction
        let effectiveSafety: SystemDataSafety
        if forceManual || guardReason != nil {
            effectiveSafety = .manual
            effectiveAction = .manual(guidance: manualGuidance ?? guardReason ?? ZtatL10n.tr(
                "受系统保护路径，请在访达或对应应用中手动管理。",
                "Protected path — manage manually in Finder or the owning application."
            ))
        } else {
            effectiveSafety = safety
            effectiveAction = .trashPaths([url])
        }

        return SystemDataItem(
            id: id,
            category: category,
            title: title,
            subtitle: subtitle,
            path: url,
            bytes: m.bytes,
            lastModified: m.newestModified,
            safety: effectiveSafety,
            recovery: recovery,
            action: effectiveAction,
            projectRoot: projectRoot,
            isStalled: m.stalled,
            isCompressible: isCompressible && guardReason == nil,
            detailNote: detailNote
        )
    }

    // MARK: - 1. APFS Local Snapshots

    public static func scanSnapshots(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        guard let out = try? await CleanerProcessRunner.runAsync("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 8),
              out.succeeded else {
            return SystemDataProbeOutput(probeID: "snapshots", items: [])
        }
        let lines = out.stdoutString.components(separatedBy: .newlines)
        var stamps: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("com.apple.TimeMachine."),
                  trimmed.hasSuffix(".local") else { continue }
            let middle = trimmed
                .replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                .replacingOccurrences(of: ".local", with: "")
            if isValidSnapshotStamp(middle) {
                stamps.append(middle)
            }
        }
        guard !stamps.isEmpty else {
            return SystemDataProbeOutput(probeID: "snapshots", items: [])
        }

        let overview = SystemDataDiskWalker.volumeOverview()
        var items: [SystemDataItem] = []

        let hasThinAll = overview.purgeableBytes >= 256 * 1_048_576
        if hasThinAll {
            let targetThin = min(overview.purgeableBytes, 10 * 1_073_741_824)
            items.append(SystemDataItem(
                id: "snapshots.thin.all",
                category: .snapshots,
                title: ZtatL10n.tr("压缩瘦身全部本地快照（\(stamps.count) 个）", "Thin All Local Snapshots (\(stamps.count))"),
                subtitle: ZtatL10n.tr(
                    "系统当前可清除空间约 \(CleanerFormatters.bytes(overview.purgeableBytes))，释放后立即归还可用容量",
                    "APFS reports ~\(CleanerFormatters.bytes(overview.purgeableBytes)) purgeable space"
                ),
                path: nil,
                bytes: overview.purgeableBytes,
                lastModified: nil,
                safety: .safe,
                recovery: .disposable,
                action: .thinSnapshots(bytes: targetThin),
                detailNote: ZtatL10n.tr(
                    "执行 `tmutil thinlocalsnapshots / <bytes> 4`，不影响外置时间机器备份。",
                    "Runs `tmutil thinlocalsnapshots / <bytes> 4`; external Time Machine backups are untouched."
                )
            ))
        }

        // When `snapshots.thin.all` already accounts for purgeableBytes, list individual snapshot stamps with 0 bytes
        // to avoid double-counting in totals/charts and prevent SpacePlan from selecting both simultaneously.
        let perSnapEstimate = hasThinAll ? 0 : (overview.purgeableBytes > 0 ? (overview.purgeableBytes / Int64(max(1, stamps.count))) : 0)
        for stamp in stamps.sorted(by: >) {
            items.append(SystemDataItem(
                id: "snapshots.stamp.\(stamp)",
                category: .snapshots,
                title: ZtatL10n.tr("时间机器快照 \(stamp)", "Time Machine Snapshot \(stamp)"),
                subtitle: "com.apple.TimeMachine.\(stamp).local",
                path: nil,
                bytes: perSnapEstimate,
                lastModified: parseSnapshotDate(stamp),
                safety: .review,
                recovery: .disposable,
                action: .deleteSnapshot(dateStamp: stamp),
                detailNote: hasThinAll
                    ? ZtatL10n.tr("空间已计入上方汇总快照池，可单独删除该时间点快照。", "Size accounted in aggregate snapshot pool above; can be deleted individually.")
                    : nil
            ))
        }

        return SystemDataProbeOutput(probeID: "snapshots", items: items)
    }

    public static func isValidSnapshotStamp(_ stamp: String) -> Bool {
        // Strict YYYY-MM-DD-HHMMSS validation
        let pattern = #"^\d{4}-\d{2}-\d{2}-\d{6}$"#
        return stamp.range(of: pattern, options: .regularExpression) != nil
    }

    private static func parseSnapshotDate(_ stamp: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        return df.date(from: stamp)
    }

    // MARK: - 2. Simulators & Runtimes

    public static func scanSimulators(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var claimed = Set<String>()

        let simCaches = ctx.homeURL("Library/Developer/CoreSimulator/Caches")
        claim(simCaches, into: &claimed)
        if let item = await measureFolderItem(
            id: "simulators.caches",
            category: .simulators,
            title: ZtatL10n.tr("CoreSimulator 共享缓存", "CoreSimulator Shared Caches"),
            subtitle: simCaches.path,
            url: simCaches,
            safety: .safe,
            recovery: .rebuildsLocally
        ) {
            items.append(item)
        }

        let runtimeVolumes = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes")
        claim(runtimeVolumes, into: &claimed)
        if let item = await measureFolderItem(
            id: "simulators.runtimes",
            category: .simulators,
            title: ZtatL10n.tr("模拟器系统镜像（Runtimes）", "Simulator OS Runtimes"),
            subtitle: runtimeVolumes.path,
            url: runtimeVolumes,
            minBytes: minCacheBytes,
            safety: .manual,
            recovery: .redownloads,
            forceManual: true,
            manualGuidance: ZtatL10n.tr(
                "请在终端运行 `xcrun simctl runtime list` 或在 Xcode → Settings → Components 中移除旧版运行时。",
                "Manage via `xcrun simctl runtime list` or Xcode → Settings → Components."
            )
        ) {
            items.append(item)
        }

        // Only invoke `xcrun simctl` when Xcode/CLT is installed so macOS never shows an install popup.
        let devicesRoot = ctx.homeURL("Library/Developer/CoreSimulator/Devices")
        claim(devicesRoot, into: &claimed)
        if FileManager.default.fileExists(atPath: devicesRoot.path),
           await hasActiveXcodeToolchain(),
           let out = try? await CleanerProcessRunner.runAsync("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 10),
           out.succeeded,
           let json = try? JSONSerialization.jsonObject(with: out.stdout) as? [String: Any],
           let byRuntime = json["devices"] as? [String: [[String: Any]]] {
            var unavailableCount = 0
            var unavailableBytes: Int64 = 0

            for (runtime, devices) in byRuntime {
                let shortRuntime = runtime.components(separatedBy: ".").last ?? runtime
                for dev in devices {
                    guard let udid = dev["udid"] as? String,
                          let name = dev["name"] as? String else { continue }
                    let isAvailable = (dev["isAvailable"] as? Bool) ?? true
                    let devDir = devicesRoot.appendingPathComponent(udid)
                    guard FileManager.default.fileExists(atPath: devDir.path) else { continue }

                    if !isAvailable {
                        let m = await SystemDataDiskWalker.measure(url: devDir, timeoutSeconds: 10)
                        unavailableCount += 1
                        unavailableBytes += m.bytes
                    } else {
                        let devCache = devDir.appendingPathComponent("data/Library/Caches")
                        if let cacheItem = await measureFolderItem(
                            id: "simulators.devcache.\(udid)",
                            category: .simulators,
                            title: ZtatL10n.tr("模拟器缓存：\(name) (\(shortRuntime))", "Simulator Cache: \(name) (\(shortRuntime))"),
                            subtitle: devCache.path,
                            url: devCache,
                            minBytes: minCacheBytes,
                            safety: .safe,
                            recovery: .rebuildsLocally
                        ) {
                            items.append(cacheItem)
                        }
                    }
                }
            }

            if unavailableCount > 0 && unavailableBytes >= minNormalBytes {
                items.append(SystemDataItem(
                    id: "simulators.unavailable.all",
                    category: .simulators,
                    title: ZtatL10n.tr("不可用的旧模拟器（\(unavailableCount) 台）", "Unavailable Simulators (\(unavailableCount))"),
                    subtitle: "xcrun simctl delete unavailable",
                    path: devicesRoot,
                    bytes: unavailableBytes,
                    safety: .safe,
                    recovery: .redownloads,
                    action: .toolCommand(
                        executable: "/usr/bin/xcrun",
                        arguments: ["simctl", "delete", "unavailable"],
                        displayCommand: "xcrun simctl delete unavailable"
                    )
                ))
            }
        }

        return SystemDataProbeOutput(probeID: "simulators", items: items, claimedPaths: claimed)
    }

    // MARK: - 3. Xcode Artifacts

    public static func scanXcode(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var claimed = Set<String>()
        let fm = FileManager.default

        let derivedRoot = ctx.homeURL("Library/Developer/Xcode/DerivedData")
        claim(derivedRoot, into: &claimed)
        if let children = try? fm.contentsOfDirectory(at: derivedRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for child in children {
                let infoPlist = child.appendingPathComponent("info.plist")
                var projectRoot: URL?
                var projectLabel = child.lastPathComponent
                if let dict = NSDictionary(contentsOf: infoPlist) as? [String: Any],
                   let wsPath = dict["WorkspacePath"] as? String {
                    let wsURL = URL(fileURLWithPath: wsPath)
                    let root = wsURL.deletingLastPathComponent()
                    projectRoot = root
                    projectLabel = root.lastPathComponent
                }
                if let item = await measureFolderItem(
                    id: "xcode.derived.\(child.lastPathComponent)",
                    category: .xcode,
                    title: ZtatL10n.tr("DerivedData：\(projectLabel)", "DerivedData: \(projectLabel)"),
                    subtitle: child.path,
                    url: child,
                    safety: .safe,
                    recovery: .rebuildsLocally,
                    projectRoot: projectRoot
                ) {
                    items.append(item)
                }
            }
        }

        let staticXcodeDirs: [(String, String, String, SystemDataSafety, SystemDataRecovery, Bool)] = [
            ("xcode.iosDeviceSupport", "Library/Developer/Xcode/iOS DeviceSupport", ZtatL10n.tr("iOS 真机调试符号", "iOS DeviceSupport Symbols"), .safe, .rebuildsLocally, true),
            ("xcode.watchDeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport", ZtatL10n.tr("watchOS 调试符号", "watchOS DeviceSupport"), .safe, .rebuildsLocally, true),
            ("xcode.tvDeviceSupport", "Library/Developer/Xcode/tvOS DeviceSupport", ZtatL10n.tr("tvOS 调试符号", "tvOS DeviceSupport"), .safe, .rebuildsLocally, true),
            ("xcode.visionDeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport", ZtatL10n.tr("visionOS 调试符号", "visionOS DeviceSupport"), .safe, .rebuildsLocally, true),
            ("xcode.previews", "Library/Developer/Xcode/UserData/Previews", ZtatL10n.tr("SwiftUI Previews 缓存", "SwiftUI Previews Cache"), .safe, .rebuildsLocally, false),
            ("xcode.archives", "Library/Developer/Xcode/Archives", ZtatL10n.tr("Xcode 归档包（Archives）", "Xcode Archives"), .review, .permanent, true)
        ]

        for (id, rel, title, safety, recovery, compressible) in staticXcodeDirs {
            let url = ctx.homeURL(rel)
            claim(url, into: &claimed)
            if let item = await measureFolderItem(
                id: id,
                category: .xcode,
                title: title,
                subtitle: url.path,
                url: url,
                safety: safety,
                recovery: recovery,
                isCompressible: compressible
            ) {
                items.append(item)
            }
        }

        return SystemDataProbeOutput(probeID: "xcode", items: items, claimedPaths: claimed)
    }

    // MARK: - 4. Package Manager Caches

    public static func scanPackages(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var claimed = Set<String>()

        let uvRunning = await isProcessRunning(exactName: "uv")

        let entries: [(String, String, String, Bool)] = [
            ("pkg.homebrew", "Library/Caches/Homebrew", "Homebrew Cache", false),
            ("pkg.npm", ".npm", "npm Cache", false),
            ("pkg.pnpm", "Library/pnpm/store", "pnpm Content-Addressable Store", false),
            ("pkg.yarn.lib", "Library/Caches/Yarn", "Yarn Cache", false),
            ("pkg.yarn.home", ".yarn/cache", "Yarn Berry Cache", false),
            ("pkg.bun", ".bun/install/cache", "Bun Package Cache", false),
            ("pkg.pip", "Library/Caches/pip", "Python pip Cache", false),
            ("pkg.uv", ".cache/uv", "uv Python Cache", uvRunning),
            ("pkg.poetry", "Library/Caches/pypoetry", "Poetry Cache", false),
            ("pkg.cargo.reg", ".cargo/registry/cache", "Cargo Registry Cache", false),
            ("pkg.cargo.git", ".cargo/git", "Cargo Git Checkouts", false),
            ("pkg.cocoapods", "Library/Caches/CocoaPods", "CocoaPods Cache", false),
            ("pkg.swiftpm", "Library/Caches/org.swift.swiftpm", "SwiftPM Cache", false),
            ("pkg.gobuild", "Library/Caches/go-build", "Go Build Cache", false),
            ("pkg.gomod", "go/pkg/mod/cache", "Go Module Download Cache", false),
            ("pkg.gradle", ".gradle/caches", "Gradle Cache", false),
            ("pkg.maven", ".m2/repository", "Maven Local Repository", false),
            ("pkg.nuget", ".nuget/packages", "NuGet Packages Cache", false),
            ("pkg.composer", "Library/Caches/composer", "Composer Cache", false)
        ]

        for (id, rel, title, lockedByRunningTool) in entries {
            let url = ctx.homeURL(rel)
            claim(url, into: &claimed)
            if let item = await measureFolderItem(
                id: id,
                category: .packages,
                title: title,
                subtitle: url.path,
                url: url,
                safety: lockedByRunningTool ? .manual : .safe,
                recovery: .redownloads,
                forceManual: lockedByRunningTool,
                manualGuidance: lockedByRunningTool
                    ? ZtatL10n.tr("检测到 uv 正在运行，请等待其结束后再清理缓存。", "uv is currently running; wait until it finishes before clearing its cache.")
                    : nil
            ) {
                items.append(item)
            }
        }

        return SystemDataProbeOutput(probeID: "packages", items: items, claimedPaths: claimed)
    }

    // MARK: - 5. AI Models & Weights

    public static func scanAIModels(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var claimed = Set<String>()
        let fm = FileManager.default

        // 5a. Ollama manifests (compute unique layer sizes per model)
        let ollamaModelsRoot = ctx.homeURL(".ollama/models")
        claim(ollamaModelsRoot, into: &claimed)
        let manifestsRoot = ollamaModelsRoot.appendingPathComponent("manifests")
        let blobsRoot = ollamaModelsRoot.appendingPathComponent("blobs")
        if fm.fileExists(atPath: manifestsRoot.path) {
            let ollamaBin = CleanerProcessRunner.resolveExecutable("ollama")
            let parsedOllama = await Task.detached(priority: .utility) { () -> (
                modelLayers: [(tag: String, digests: Set<String>, totalBytes: Int64, modDate: Date?)],
                digestRefCount: [String: Int],
                digestSizes: [String: Int64]
            ) in
                let localFM = FileManager.default
                var modelLayers: [(tag: String, digests: Set<String>, totalBytes: Int64, modDate: Date?)] = []
                var digestRefCount: [String: Int] = [:]
                var digestSizes: [String: Int64] = [:]
                let rootPrefix = manifestsRoot.standardizedFileURL.path + "/"

                if let enumerator = localFM.enumerator(at: manifestsRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        if Task.isCancelled { break }
                        guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                              vals.isSymbolicLink != true,
                              vals.isRegularFile == true else { continue }
                        guard let data = try? Data(contentsOf: fileURL),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        var digests = Set<String>()
                        var sum: Int64 = 0
                        if let cfg = obj["config"] as? [String: Any], let d = cfg["digest"] as? String {
                            digests.insert(d)
                            let s = (cfg["size"] as? NSNumber)?.int64Value ?? 0
                            digestSizes[d] = max(digestSizes[d] ?? 0, s)
                            sum += s
                        }
                        if let layers = obj["layers"] as? [[String: Any]] {
                            for layer in layers {
                                if let d = layer["digest"] as? String {
                                    digests.insert(d)
                                    let s = (layer["size"] as? NSNumber)?.int64Value ?? 0
                                    digestSizes[d] = max(digestSizes[d] ?? 0, s)
                                    sum += s
                                }
                            }
                        }
                        for d in digests { digestRefCount[d, default: 0] += 1 }
                        let stdPath = fileURL.standardizedFileURL.path
                        let rel = stdPath.hasPrefix(rootPrefix) ? String(stdPath.dropFirst(rootPrefix.count)) : fileURL.lastPathComponent
                        let relParts = rel.split(separator: "/").map(String.init)
                        let tagName: String
                        if relParts.count >= 4, relParts[0] == "registry.ollama.ai", relParts[1] == "library" {
                            let model = relParts[2..<(relParts.count - 1)].joined(separator: "/")
                            tagName = "\(model):\(relParts.last!)"
                        } else if relParts.count >= 2 {
                            let model = relParts[0..<(relParts.count - 1)].joined(separator: "/")
                            tagName = "\(model):\(relParts.last!)"
                        } else {
                            tagName = fileURL.lastPathComponent
                        }
                        modelLayers.append((tagName, digests, sum, vals.contentModificationDate))
                    }
                }
                return (modelLayers, digestRefCount, digestSizes)
            }.value

            for entry in parsedOllama.modelLayers {
                let uniqueBytes = entry.digests.reduce(Int64(0)) { acc, digest in
                    if (parsedOllama.digestRefCount[digest] ?? 0) == 1 {
                        return acc + (parsedOllama.digestSizes[digest] ?? 0)
                    }
                    return acc
                }
                let displayBytes = uniqueBytes > 0 ? uniqueBytes : entry.totalBytes
                guard displayBytes >= minNormalBytes else { continue }
                let isSafeTag = isValidOllamaTag(entry.tag)
                let action: SystemDataAction
                if let ollamaBin, isSafeTag {
                    action = .toolCommand(executable: ollamaBin, arguments: ["rm", "--", entry.tag], displayCommand: "ollama rm \(entry.tag)")
                } else {
                    action = .manual(guidance: ZtatL10n.tr("请在终端确认并运行 `ollama rm` 移除该模型。", "Run `ollama rm` in Terminal to remove this model."))
                }
                items.append(SystemDataItem(
                    id: "ai.ollama.\(entry.tag)",
                    category: .aiModels,
                    title: "Ollama: \(entry.tag)",
                    subtitle: blobsRoot.path,
                    path: ollamaModelsRoot,
                    bytes: displayBytes,
                    lastModified: entry.modDate,
                    safety: (ollamaBin != nil && isSafeTag) ? .review : .manual,
                    recovery: .redownloads,
                    action: action,
                    detailNote: uniqueBytes < entry.totalBytes
                        ? ZtatL10n.tr("独占权重 \(CleanerFormatters.bytes(uniqueBytes))（总引用 \(CleanerFormatters.bytes(entry.totalBytes))）",
                                     "Unique layers \(CleanerFormatters.bytes(uniqueBytes)) (total \(CleanerFormatters.bytes(entry.totalBytes)))")
                        : nil
                ))
            }
        }

        // 5b. Hugging Face Hub models
        let hfHub = ctx.homeURL(".cache/huggingface/hub")
        claim(hfHub, into: &claimed)
        if let children = try? fm.contentsOfDirectory(at: hfHub, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for child in children where child.lastPathComponent.hasPrefix("models--") || child.lastPathComponent.hasPrefix("datasets--") {
                let pretty = child.lastPathComponent
                    .replacingOccurrences(of: "models--", with: "")
                    .replacingOccurrences(of: "datasets--", with: "[dataset] ")
                    .replacingOccurrences(of: "--", with: "/")
                if let item = await measureFolderItem(
                    id: "ai.hf.\(child.lastPathComponent)",
                    category: .aiModels,
                    title: "Hugging Face: \(pretty)",
                    subtitle: child.path,
                    url: child,
                    minBytes: minCacheBytes,
                    safety: .review,
                    recovery: .redownloads,
                    isCompressible: true
                ) {
                    items.append(item)
                }
            }
        }

        // 5c. Other local AI model stores
        let otherAI: [(String, String, String)] = [
            ("ai.lmstudio", ".cache/lm-studio/models", "LM Studio Models"),
            ("ai.torch", ".cache/torch", "PyTorch Hub Cache"),
            ("ai.whisper", ".cache/whisper", "Whisper Models"),
            ("ai.mlx", ".cache/mlx", "Apple MLX Cache")
        ]
        for (id, rel, title) in otherAI {
            let url = ctx.homeURL(rel)
            claim(url, into: &claimed)
            if let item = await measureFolderItem(
                id: id,
                category: .aiModels,
                title: title,
                subtitle: url.path,
                url: url,
                minBytes: minCacheBytes,
                safety: .review,
                recovery: .redownloads,
                isCompressible: true
            ) {
                items.append(item)
            }
        }

        return SystemDataProbeOutput(probeID: "aiModels", items: items, claimedPaths: claimed)
    }

    // MARK: - 6. Docker & Containers

    public static func scanDocker(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var claimed = Set<String>()

        let dockerRaw = ctx.homeURL("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        claim(ctx.homeURL("Library/Containers/com.docker.docker"), into: &claimed)
        if let item = await measureFolderItem(
            id: "docker.desktop.raw",
            category: .docker,
            title: ZtatL10n.tr("Docker Desktop 虚拟磁盘镜像", "Docker Desktop VM Disk (Docker.raw)"),
            subtitle: dockerRaw.path,
            url: dockerRaw,
            minBytes: minCacheBytes,
            safety: .manual,
            recovery: .redownloads,
            forceManual: true,
            manualGuidance: ZtatL10n.tr(
                "请使用下方 Docker 清理命令或 Docker Desktop → Settings → Resources 缩容，切勿直接删除运行中的 Docker.raw。",
                "Use Docker prune actions below or Docker Desktop settings; never trash Docker.raw directly."
            )
        ) {
            items.append(item)
        }

        let orbData = ctx.homeURL("Library/Group Containers/HUAQ24HBR6.dev.orbstack")
        claim(orbData, into: &claimed)
        if let item = await measureFolderItem(
            id: "docker.orbstack",
            category: .docker,
            title: ZtatL10n.tr("OrbStack 容器与 Linux 虚拟机", "OrbStack Data Store"),
            subtitle: orbData.path,
            url: orbData,
            minBytes: minCacheBytes,
            safety: .manual,
            recovery: .redownloads,
            forceManual: true,
            manualGuidance: ZtatL10n.tr("请在 OrbStack 应用或 `docker system prune` 中管理容器与镜像。", "Manage inside OrbStack or via `docker system prune`.")
        ) {
            items.append(item)
        }

        let colima = ctx.homeURL(".colima")
        claim(colima, into: &claimed)
        if let item = await measureFolderItem(
            id: "docker.colima",
            category: .docker,
            title: "Colima Container VM",
            subtitle: colima.path,
            url: colima,
            minBytes: minCacheBytes,
            safety: .manual,
            recovery: .redownloads,
            forceManual: true,
            manualGuidance: ZtatL10n.tr("请使用 `colima delete` 或 `docker system prune` 清理。", "Clean using `colima delete` or `docker system prune`.")
        ) {
            items.append(item)
        }

        // Query live Docker daemon first so we don't double-count reclaimable slices inside VM disk images
        var dfItems: [SystemDataItem] = []
        var dfReclaimableTotal: Int64 = 0
        if let dockerBin = CleanerProcessRunner.resolveExecutable("docker"),
           let dfOut = try? await CleanerProcessRunner.runAsync(dockerBin, ["system", "df", "--format", "{{json .}}"], timeout: 5),
           dfOut.succeeded {
            for line in dfOut.stdoutString.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = obj["Type"] as? String,
                      let reclaimStr = obj["Reclaimable"] as? String else { continue }
                let reclaimBytes = parseHumanBytes(reclaimStr.components(separatedBy: " ").first ?? reclaimStr)
                guard reclaimBytes >= minNormalBytes else { continue }

                if kind.lowercased().contains("build cache") {
                    dfReclaimableTotal += reclaimBytes
                    dfItems.append(SystemDataItem(
                        id: "docker.df.buildcache",
                        category: .docker,
                        title: ZtatL10n.tr("Docker 构建缓存（可回收）", "Docker Build Cache (Reclaimable)"),
                        subtitle: "docker builder prune -af",
                        bytes: reclaimBytes,
                        safety: .safe,
                        recovery: .rebuildsLocally,
                        action: .toolCommand(executable: dockerBin, arguments: ["builder", "prune", "-af"], displayCommand: "docker builder prune -af")
                    ))
                } else if kind.lowercased().contains("images") {
                    dfReclaimableTotal += reclaimBytes
                    dfItems.append(SystemDataItem(
                        id: "docker.df.images",
                        category: .docker,
                        title: ZtatL10n.tr("Docker 未引用镜像（可回收）", "Unused Docker Images (Reclaimable)"),
                        subtitle: "docker image prune -af",
                        bytes: reclaimBytes,
                        safety: .review,
                        recovery: .redownloads,
                        action: .toolCommand(executable: dockerBin, arguments: ["image", "prune", "-af"], displayCommand: "docker image prune -af")
                    ))
                }
            }
        }

        // Subtract already-attributed reclaimable slices from the largest VM disk so totalMeasuredBytes never double-counts
        if dfReclaimableTotal > 0, let largestIdx = items.indices.max(by: { items[$0].bytes < items[$1].bytes }) {
            let orig = items[largestIdx]
            let netBytes = max(0, orig.bytes - dfReclaimableTotal)
            items[largestIdx] = SystemDataItem(
                id: orig.id,
                category: orig.category,
                title: orig.title,
                subtitle: orig.subtitle,
                path: orig.path,
                bytes: netBytes,
                lastModified: orig.lastModified,
                safety: orig.safety,
                recovery: orig.recovery,
                action: orig.action,
                detailNote: ZtatL10n.tr(
                    "总磁盘镜像 \(CleanerFormatters.bytes(orig.bytes))（已扣除下方单独列出的 \(CleanerFormatters.bytes(dfReclaimableTotal)) 可回收切片）。",
                    "Total VM disk \(CleanerFormatters.bytes(orig.bytes)) (net of \(CleanerFormatters.bytes(dfReclaimableTotal)) reclaimable slices listed below)."
                )
            )
        }
        items.append(contentsOf: dfItems)

        return SystemDataProbeOutput(probeID: "docker", items: items, claimedPaths: claimed)
    }

    // MARK: - 7. Virtual Machines

    public static func scanVirtualMachines(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var claimed = Set<String>()
        let fm = FileManager.default

        let vmRoots: [(String, String, String)] = [
            ("utm", "Library/Containers/com.utmapp.UTM/Data/Documents", "UTM"),
            ("parallels", "Parallels", "Parallels"),
            ("vmware", "Virtual Machines.localized", "VMware Fusion"),
            ("vbox", "VirtualBox VMs", "VirtualBox"),
            ("lima", ".lima", "Lima"),
            ("tart", ".tart/vms", "Tart")
        ]

        for (prefix, rel, label) in vmRoots {
            let dir = ctx.homeURL(rel)
            claim(dir, into: &claimed)
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                if let item = await measureFolderItem(
                    id: "vm.\(prefix).\(child.lastPathComponent)",
                    category: .virtualMachines,
                    title: "\(label): \(child.lastPathComponent)",
                    subtitle: child.path,
                    url: child,
                    minBytes: minCacheBytes,
                    safety: .review,
                    recovery: .permanent,
                    isCompressible: false
                ) {
                    items.append(item)
                }
            }
        }

        return SystemDataProbeOutput(probeID: "virtualMachines", items: items, claimedPaths: claimed)
    }

    // MARK: - 8. Developer Toolchains & IDEs

    public static func scanDevTools(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var claimed = Set<String>()
        let fm = FileManager.default

        // JetBrains caches (separate current vs superseded older versions per IDE)
        let jbCaches = ctx.homeURL("Library/Caches/JetBrains")
        claim(jbCaches, into: &claimed)
        if let children = try? fm.contentsOfDirectory(at: jbCaches, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for child in children {
                if let item = await measureFolderItem(
                    id: "devtools.jetbrains.cache.\(child.lastPathComponent)",
                    category: .devTools,
                    title: "JetBrains Cache: \(child.lastPathComponent)",
                    subtitle: child.path,
                    url: child,
                    safety: .safe,
                    recovery: .rebuildsLocally
                ) {
                    items.append(item)
                }
            }
        }

        let staticDev: [(String, String, String, SystemDataSafety, SystemDataRecovery, Bool)] = [
            ("devtools.android.sdk", "Library/Android/sdk", "Android SDK", .review, .redownloads, true),
            ("devtools.android.avd", ".android/avd", "Android Virtual Devices (AVD)", .review, .redownloads, true),
            ("devtools.vscode.cache", "Library/Application Support/Code/CachedData", "VS Code CachedData", .safe, .rebuildsLocally, false),
            ("devtools.vscode.webcache", "Library/Application Support/Code/Cache", "VS Code Cache", .safe, .rebuildsLocally, false),
            ("devtools.cursor.cache", "Library/Application Support/Cursor/CachedData", "Cursor CachedData", .safe, .rebuildsLocally, false),
            ("devtools.zed.cache", "Library/Caches/dev.zed.Zed", "Zed Editor Cache", .safe, .rebuildsLocally, false),
            ("devtools.rustup", ".rustup/toolchains", "Rustup Toolchains", .review, .redownloads, true),
            ("devtools.conda.pkgs", ".conda/pkgs", "Conda Downloaded Packages", .safe, .redownloads, false),
            ("devtools.unity", "Library/Unity", "Unity Editor Cache & Packages", .review, .redownloads, true)
        ]

        for (id, rel, title, safety, recovery, compressible) in staticDev {
            let url = ctx.homeURL(rel)
            claim(url, into: &claimed)
            if let item = await measureFolderItem(
                id: id,
                category: .devTools,
                title: title,
                subtitle: url.path,
                url: url,
                safety: safety,
                recovery: recovery,
                isCompressible: compressible
            ) {
                items.append(item)
            }
        }

        return SystemDataProbeOutput(probeID: "devTools", items: items, claimedPaths: claimed)
    }

    // MARK: - 9. Logs & Diagnostics

    public static func scanLogs(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var claimed = Set<String>()
        let fm = FileManager.default

        let userLogs = ctx.homeURL("Library/Logs")
        claim(userLogs, into: &claimed)
        if let children = try? fm.contentsOfDirectory(at: userLogs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for child in children {
                if let item = await measureFolderItem(
                    id: "logs.user.\(child.lastPathComponent)",
                    category: .logs,
                    title: ZtatL10n.tr("应用日志：\(child.lastPathComponent)", "App Logs: \(child.lastPathComponent)"),
                    subtitle: child.path,
                    url: child,
                    minBytes: 5 * 1_048_576,
                    safety: .safe,
                    recovery: .disposable
                ) {
                    items.append(item)
                }
            }
        }

        let diagReports = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
        claim(diagReports, into: &claimed)
        let diagStaleBytes = await measureStaleRegularFiles(in: diagReports, olderThanDays: 7)
        if diagStaleBytes >= 5 * 1_048_576 {
            items.append(SystemDataItem(
                id: "logs.sys.diagnosticReports",
                category: .logs,
                title: ZtatL10n.tr("系统崩溃与诊断报告（超过 7 天）", "System Diagnostic Reports (> 7 days)"),
                subtitle: diagReports.path,
                path: diagReports,
                bytes: diagStaleBytes,
                safety: .safe,
                recovery: .disposable,
                action: .pruneOlderThan(directory: diagReports, days: 7),
                detailNote: ZtatL10n.tr(
                    "仅清理超过 7 天的旧诊断报告文件，保留系统目录与近期崩溃日志。",
                    "Prunes only report files older than 7 days; preserves the system directory and recent crash logs."
                )
            ))
        }

        // Unified logging stores (read-only visibility)
        for (id, path, title) in [
            ("logs.sys.unified", "/private/var/db/diagnostics", ZtatL10n.tr("macOS 统一日志库（Unified Log）", "macOS Unified Log Store")),
            ("logs.sys.uuidtext", "/private/var/db/uuidtext", ZtatL10n.tr("系统日志符号文本库", "Unified Log UUIDText"))
        ] {
            let url = URL(fileURLWithPath: path)
            claim(url, into: &claimed)
            if let item = await measureFolderItem(
                id: id,
                category: .logs,
                title: title,
                subtitle: path,
                url: url,
                minBytes: minCacheBytes,
                safety: .manual,
                recovery: .disposable,
                forceManual: true,
                manualGuidance: ZtatL10n.tr("由 macOS logd 自动轮转，仅作空间透明展示。", "Managed automatically by macOS logd; shown for transparency.")
            ) {
                items.append(item)
            }
        }

        return SystemDataProbeOutput(probeID: "logs", items: items, claimedPaths: claimed)
    }

    // MARK: - 10. Stale Temporary Files

    public static func scanTemporary(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var claimed = Set<String>()

        let darwinCache = confstrPath(_CS_DARWIN_USER_CACHE_DIR)
        let darwinTemp = confstrPath(_CS_DARWIN_USER_TEMP_DIR)

        for (id, maybePath, label) in [
            ("temp.darwin.temp", darwinTemp, ZtatL10n.tr("用户临时目录（超过 3 天）", "User Temp Directory (> 3 days)")),
            ("temp.darwin.cache", darwinCache, ZtatL10n.tr("Darwin 用户级系统缓存（超过 3 天）", "Darwin User Cache (> 3 days)"))
        ] {
            guard let path = maybePath else { continue }
            let dirURL = URL(fileURLWithPath: path, isDirectory: true)
            claim(dirURL, into: &claimed)
            let staleBytes = await measureStaleRegularFiles(in: dirURL, olderThanDays: 3)
            guard staleBytes >= minNormalBytes else { continue }
            items.append(SystemDataItem(
                id: id,
                category: .temporary,
                title: label,
                subtitle: dirURL.path,
                path: dirURL,
                bytes: staleBytes,
                safety: .safe,
                recovery: .disposable,
                action: .pruneOlderThan(directory: dirURL, days: 3),
                detailNote: ZtatL10n.tr(
                    "仅移除超过 3 天的普通文件，自动保留活跃套接字、符号链接与近期文件。",
                    "Prunes only regular files older than 3 days; preserves live sockets, symlinks, and recent files."
                )
            ))
        }

        return SystemDataProbeOutput(probeID: "temporary", items: items, claimedPaths: claimed)
    }

    private static func confstrPath(_ name: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(name, &buf, buf.count)
        guard len > 0, len < buf.count else { return nil }
        return String(cString: buf)
    }

    private static func measureStaleRegularFiles(in dir: URL, olderThanDays days: Int) async -> Int64 {
        guard !Task.isCancelled else { return 0 }
        let worker = Task.detached(priority: .utility) { () -> Int64 in
            let fm = FileManager.default
            let cleanDir = dir.standardizedFileURL
            guard (try? fm.destinationOfSymbolicLink(atPath: cleanDir.path)) == nil else { return 0 }
            let startVolume = SystemDataDiskWalker.volumeIdentifier(of: cleanDir)
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            let keys: [URLResourceKey] = [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey, .volumeIdentifierKey
            ]
            guard let enumerator = fm.enumerator(at: cleanDir, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
                return 0
            }
            var total: Int64 = 0
            var count = 0
            while let file = enumerator.nextObject() as? URL {
                count += 1
                if count & 0xFF == 0, Task.isCancelled { break }
                if count > 40_000 { break }
                guard let vals = try? file.resourceValues(forKeys: Set(keys)) else { continue }
                if vals.isSymbolicLink == true {
                    if vals.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                if let startVolume,
                   let childVol = vals.volumeIdentifier as? NSObject,
                   !startVolume.isEqual(childVol) {
                    if vals.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                guard vals.isRegularFile == true,
                      let mod = vals.contentModificationDate,
                      mod < cutoff else { continue }
                total += Int64(vals.totalFileAllocatedSize ?? vals.fileSize ?? 0)
            }
            return total
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    // MARK: - 11. iOS Device Backups

    public static func scanDeviceBackups(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var claimed = Set<String>()
        let fm = FileManager.default
        let backupRoot = ctx.homeURL("Library/Application Support/MobileSync/Backup")
        claim(backupRoot, into: &claimed)

        guard let children = try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return SystemDataProbeOutput(probeID: "deviceBackups", items: [], claimedPaths: claimed)
        }
        for child in children {
            var displayName = child.lastPathComponent
            var detail: String?
            let plist = child.appendingPathComponent("Info.plist")
            if let dict = NSDictionary(contentsOf: plist) as? [String: Any] {
                let device = (dict["Device Name"] as? String) ?? displayName
                let ver = (dict["Product Version"] as? String) ?? ""
                displayName = ver.isEmpty ? device : "\(device) (iOS \(ver))"
                if let lastBackup = dict["Last Backup Date"] as? Date {
                    let df = DateFormatter()
                    df.dateStyle = .medium
                    detail = ZtatL10n.tr("上次备份：\(df.string(from: lastBackup))", "Last backup: \(df.string(from: lastBackup))")
                }
            }
            if let item = await measureFolderItem(
                id: "backup.ios.\(child.lastPathComponent)",
                category: .deviceBackups,
                title: ZtatL10n.tr("iOS 备份：\(displayName)", "iOS Backup: \(displayName)"),
                subtitle: child.path,
                url: child,
                minBytes: minCacheBytes,
                safety: .review,
                recovery: .permanent,
                isCompressible: true,
                detailNote: detail
            ) {
                items.append(item)
            }
        }

        return SystemDataProbeOutput(probeID: "deviceBackups", items: items, claimedPaths: claimed)
    }

    // MARK: - 12. Shared Data

    public static func scanSharedData(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var claimed = Set<String>()
        let sharedRoot = URL(fileURLWithPath: "/Users/Shared")
        claim(sharedRoot, into: &claimed)

        guard let children = try? FileManager.default.contentsOfDirectory(at: sharedRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return SystemDataProbeOutput(probeID: "sharedData", items: [], claimedPaths: claimed)
        }
        for child in children {
            if let item = await measureFolderItem(
                id: "shared.\(child.lastPathComponent)",
                category: .sharedData,
                title: "/Users/Shared/\(child.lastPathComponent)",
                subtitle: child.path,
                url: child,
                minBytes: minCacheBytes,
                safety: .manual,
                recovery: .permanent,
                forceManual: true,
                manualGuidance: ZtatL10n.tr(
                    "/Users/Shared 可能包含多用户共享数据或 Apple 授权文件（如 SC Info），仅作透明展示，请在访达中自行确认处理。",
                    "/Users/Shared may hold multi-user data or Apple licensing files (e.g. SC Info); inspect manually in Finder."
                )
            ) {
                items.append(item)
            }
        }
        return SystemDataProbeOutput(probeID: "sharedData", items: items, claimedPaths: claimed)
    }

    // MARK: - 13. Project Build Artifacts (Repo-Grouped)

    private static let safeArtifactNames: Set<String> = [
        "node_modules", ".build", "Pods", ".next", ".nuxt", ".turbo", ".gradle", "DerivedData"
    ]
    private static let conditionalArtifactNames: Set<String> = [
        "target", ".venv", "venv", "dist", "build"
    ]

    public static func scanProjects(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var claimed = Set<String>()
        let fm = FileManager.default

        var searchRoots: [URL] = [
            "Projects", "Developer", "Code", "Workspace", "Global-repos", "Repos", "src", "Documents", "Desktop"
        ].map { ctx.homeURL($0) }.filter { fm.fileExists(atPath: $0.path) }

        if ctx.includeExternalVolumes {
            let volumesURL = URL(fileURLWithPath: "/Volumes")
            if let vols = try? fm.contentsOfDirectory(at: volumesURL, includingPropertiesForKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey], options: [.skipsHiddenFiles]) {
                for vol in vols {
                    guard !SystemDataDiskWalker.isOnBootVolume(vol) else { continue }
                    let vals = try? vol.resourceValues(forKeys: [.volumeIsReadOnlyKey])
                    if vals?.volumeIsReadOnly == true { continue }
                    searchRoots.append(vol)
                }
            }
        }

        let rootsToScan = searchRoots
        let discoveredArtifacts = await Task.detached(priority: .utility) { () -> [(artifactURL: URL, projectRoot: URL, isSafe: Bool)] in
            var out: [(artifactURL: URL, projectRoot: URL, isSafe: Bool)] = []
            var visitedRoots = Set<String>()
            for root in rootsToScan {
                if Task.isCancelled { break }
                let canon = SystemDataDiskWalker.canonicalPath(root)
                guard visitedRoots.insert(canon).inserted else { continue }
                collectProjectArtifacts(in: root, depth: 0, maxDepth: 4, into: &out)
            }
            return out
        }.value

        for entry in discoveredArtifacts {
            if Task.isCancelled { break }
            claim(entry.artifactURL, into: &claimed)
            let projName = entry.projectRoot.lastPathComponent
            let artName = entry.artifactURL.lastPathComponent
            if let item = await measureFolderItem(
                id: "project.\(entry.artifactURL.standardizedFileURL.path)",
                category: .projects,
                title: "\(projName) / \(artName)",
                subtitle: entry.artifactURL.path,
                url: entry.artifactURL,
                minBytes: minNormalBytes,
                safety: entry.isSafe ? .safe : .review,
                recovery: .rebuildsLocally,
                projectRoot: entry.projectRoot,
                isCompressible: true
            ) {
                items.append(item)
            }
        }

        return SystemDataProbeOutput(probeID: "projects", items: items, claimedPaths: claimed)
    }

    private static func collectProjectArtifacts(
        in dir: URL,
        depth: Int,
        maxDepth: Int,
        into out: inout [(artifactURL: URL, projectRoot: URL, isSafe: Bool)]
    ) {
        guard depth <= maxDepth, out.count < 250 else { return }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return }

        let siblingNames = Set(children.map(\.lastPathComponent))
        let looksLikeProject = siblingNames.contains("package.json")
            || siblingNames.contains("Package.swift")
            || siblingNames.contains("Cargo.toml")
            || siblingNames.contains("pyproject.toml")
            || siblingNames.contains("requirements.txt")
            || siblingNames.contains("pom.xml")
            || siblingNames.contains("build.gradle")
            || siblingNames.contains("CMakeLists.txt")
            || siblingNames.contains(".git")

        for child in children {
            guard let vals = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  vals.isSymbolicLink != true,
                  vals.isDirectory == true else { continue }
            let name = child.lastPathComponent
            if name == ".git" || name.hasSuffix(".app") || name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                continue
            }

            if safeArtifactNames.contains(name) {
                out.append((child, dir, true))
                continue
            }
            if conditionalArtifactNames.contains(name) && looksLikeProject {
                let isCargoOrMavenTarget = (name == "target") && (siblingNames.contains("Cargo.toml") || siblingNames.contains("pom.xml"))
                if name != "target" || isCargoOrMavenTarget {
                    out.append((child, dir, isCargoOrMavenTarget))
                    continue
                }
            }
            if name.hasPrefix(".") { continue }
            if depth < maxDepth {
                collectProjectArtifacts(in: child, depth: depth + 1, maxDepth: maxDepth, into: &out)
            }
        }
    }

    // MARK: - 14. System Reserved & Cloud (Read-Only Transparency)

    public static func scanSystemReserved(_ ctx: SystemDataScanContext) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var claimed = Set<String>()

        let entries: [(String, URL, String, String)] = [
            ("sys.vm", URL(fileURLWithPath: "/private/var/vm"),
             ZtatL10n.tr("虚拟内存交换与休眠镜像（Swap / Sleepimage）", "Virtual Memory Swap & Sleepimage"),
             ZtatL10n.tr("由 macOS 内核动态分配，重启系统后自动回收。", "Managed by the macOS kernel; automatically reclaimed on reboot.")),
            ("sys.icloud", ctx.homeURL("Library/Mobile Documents"),
             ZtatL10n.tr("iCloud 云盘本地缓存", "iCloud Drive Local Cache"),
             ZtatL10n.tr("请在访达中对 iCloud 文件右键选择「移除下载项」。", "Use Finder's 'Remove Download' on iCloud Drive files to free local space.")),
            ("sys.daemonContainers", ctx.homeURL("Library/Daemon Containers"),
             ZtatL10n.tr("系统后台守护进程容器", "Daemon Containers"),
             ZtatL10n.tr("由系统服务自动维护，仅作空间透明展示。", "Managed by macOS background daemons; read-only visibility.")),
            ("sys.updates", URL(fileURLWithPath: "/Library/Updates"),
             ZtatL10n.tr("macOS 系统更新暂存包", "macOS Software Update Staging"),
             ZtatL10n.tr("系统更新完成后自动清理，请勿手动强删。", "Automatically purged after macOS updates complete."))
        ]

        for (id, url, title, guidance) in entries {
            claim(url, into: &claimed)
            if let item = await measureFolderItem(
                id: id,
                category: .systemReserved,
                title: title,
                subtitle: url.path,
                url: url,
                minBytes: minCacheBytes,
                safety: .manual,
                recovery: .disposable,
                forceManual: true,
                manualGuidance: guidance
            ) {
                items.append(item)
            }
        }

        return SystemDataProbeOutput(probeID: "systemReserved", items: items, claimedPaths: claimed)
    }

    // MARK: - 15. Claim-Aware App Caches & Catch-All Large Folders

    public static func scanClaimAwareLargeFolders(
        _ ctx: SystemDataScanContext,
        claimedPaths: Set<String>
    ) async -> SystemDataProbeOutput {
        var items: [SystemDataItem] = []
        var localClaimed = claimedPaths
        let fm = FileManager.default

        // 15a. ~/Library/Caches >= 50 MB (not already claimed)
        let cachesRoot = ctx.homeURL("Library/Caches")
        if let children = try? fm.contentsOfDirectory(at: cachesRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for child in children {
                if Task.isCancelled { break }
                let name = child.lastPathComponent
                let lower = name.lowercased()
                if lower.hasPrefix("com.apple.") || lower.hasPrefix("dev.ztat.app") { continue }
                if isClaimed(child, in: localClaimed) { continue }
                if SafePathGuard.rejectionReason(for: child) != nil { continue }

                if let item = await measureFolderItem(
                    id: "cache.app.\(name)",
                    category: .appCaches,
                    title: ZtatL10n.tr("应用缓存：\(name)", "App Cache: \(name)"),
                    subtitle: child.path,
                    url: child,
                    minBytes: minCacheBytes,
                    safety: .safe,
                    recovery: .rebuildsLocally
                ) {
                    claim(child, into: &localClaimed)
                    items.append(item)
                }
            }
        }

        // 15b. Unclaimed large folders >= 150 MB in Application Support / Containers / Group Containers
        let roots: [(URL, String)] = [
            (ctx.homeURL("Library/Application Support"), "Application Support"),
            (ctx.homeURL("Library/Containers"), "Containers"),
            (ctx.homeURL("Library/Group Containers"), "Group Containers")
        ]

        let protectedAppleSupportNames: Set<String> = [
            "addressbook", "apple", "callhistorydb", "clouddocs", "crashreporter",
            "dock", "fileprovider", "icloud", "knowledge", "mobilesync", "syncservices"
        ]

        for (root, label) in roots {
            guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                if Task.isCancelled { break }
                let name = child.lastPathComponent
                let lower = name.lowercased()
                if SafePathGuard.isAppleBundleIdentifier(name)
                    || lower.hasPrefix("com.apple.")
                    || lower.hasPrefix("group.com.apple.")
                    || lower.hasPrefix("dev.ztat.app")
                    || lower == "ztat"
                    || (label == "Application Support" && protectedAppleSupportNames.contains(lower)) {
                    continue
                }
                if isClaimed(child, in: localClaimed) { continue }
                if SafePathGuard.rejectionReason(for: child) != nil { continue }

                if let item = await measureFolderItem(
                    id: "large.\(label).\(name)",
                    category: .largeFolders,
                    title: "\(name)",
                    subtitle: child.path,
                    url: child,
                    minBytes: minCatchAllBytes,
                    safety: .review,
                    recovery: .permanent,
                    isCompressible: false,
                    detailNote: ZtatL10n.tr("位于 \(label) 的大型应用数据目录，清理前请确认无重要离线数据。",
                                            "Large data folder in \(label). Review before removing offline data.")
                ) {
                    claim(child, into: &localClaimed)
                    items.append(item)
                }
            }
        }

        return SystemDataProbeOutput(probeID: "largeFolders", items: items, claimedPaths: localClaimed)
    }

    // MARK: - Validators & Parsers

    public static func isValidOllamaTag(_ tag: String) -> Bool {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._/-]*:[A-Za-z0-9._-]+$"#
        return tag.range(of: pattern, options: .regularExpression) != nil
    }

    public static func parseHumanBytes(_ raw: String) -> Int64 {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let multipliers: [(String, Double)] = [
            ("TB", 1_000_000_000_000),
            ("TIB", 1_099_511_627_776),
            ("GB", 1_000_000_000),
            ("GIB", 1_073_741_824),
            ("MB", 1_000_000),
            ("MIB", 1_048_576),
            ("KB", 1_000),
            ("KIB", 1_024),
            ("B", 1)
        ]
        for (suffix, mult) in multipliers {
            if s.hasSuffix(suffix) {
                let numStr = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                if let val = Double(numStr) {
                    return Int64(max(0, val * mult))
                }
            }
        }
        return 0
    }
}
