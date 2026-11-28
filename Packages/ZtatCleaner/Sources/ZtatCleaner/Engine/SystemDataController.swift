// SPDX-License-Identifier: GPL-3.0-or-later
// MainActor state controller for ztat's native System Data Unpacked module.
// Strict zero-idle: no background timers; scans run only on user demand and cancel on window close.

import Combine
import Foundation
import LocalAuthentication
import ZtatCore

public struct SystemDataCategorySummary: Identifiable, Sendable {
    public let category: SystemDataCategory
    public let items: [SystemDataItem]
    public let totalBytes: Int64
    public let safeBytes: Int64
    public let reviewBytes: Int64
    public let manualBytes: Int64

    public var id: String { category.id }
}

@MainActor
public final class SystemDataController: ObservableObject {
    @Published public private(set) var volumeOverview: SystemDataVolumeOverview = SystemDataVolumeOverview(totalBytes: 0, availableBytes: 0, importantAvailableBytes: 0)
    @Published public private(set) var hasFullDiskAccess: Bool = true
    @Published public private(set) var items: [SystemDataItem] = []
    @Published public private(set) var categorySummaries: [SystemDataCategorySummary] = []
    @Published public private(set) var projectGroups: [ProjectFootprintGroup] = []
    @Published public private(set) var scanHistory: [SystemDataScanRecord] = []
    @Published public private(set) var returnedItems: [SystemDataReturnedItem] = []
    @Published public private(set) var weekDeltaBytes: Int64? = nil

    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var hasScannedOnce: Bool = false
    @Published public private(set) var completedProbes: Int = 0
    @Published public private(set) var totalProbes: Int = 0
    @Published public private(set) var currentProbeLabel: String = ""
    @Published public private(set) var isReclaiming: Bool = false
    @Published public private(set) var isCompressingID: String? = nil

    @Published public var selectedItemIDs: Set<String> = []
    @Published public var activeSpacePlan: SpacePlanProposal? = nil

    private var scanTask: Task<Void, Never>?
    private var didLoadInitialOverview = false

    public init() {}

    /// Loads volume overview, FDA status, and history off the main thread on first view appearance.
    public func refreshOverviewIfNeeded() {
        guard !didLoadInitialOverview else { return }
        didLoadInitialOverview = true
        Task { [weak self] in
            let meta = await Task.detached(priority: .utility) {
                (
                    SystemDataDiskWalker.volumeOverview(),
                    SystemDataDiskWalker.hasFullDiskAccess(),
                    SystemDataHistoryStore.shared.currentSnapshot().scans
                )
            }.value
            guard let self else { return }
            self.volumeOverview = meta.0
            self.hasFullDiskAccess = meta.1
            self.scanHistory = meta.2
        }
    }

    // MARK: - Computed Totals

    public var totalMeasuredBytes: Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    public var totalSafeBytes: Int64 {
        items.filter { $0.safety == .safe && $0.action.isActionable }.reduce(0) { $0 + $1.bytes }
    }

    public var totalReviewBytes: Int64 {
        items.filter { $0.safety == .review && $0.action.isActionable }.reduce(0) { $0 + $1.bytes }
    }

    public var totalManualBytes: Int64 {
        items.filter { $0.safety == .manual || !$0.action.isActionable }.reduce(0) { $0 + $1.bytes }
    }

    public var selectedItems: [SystemDataItem] {
        items.filter { selectedItemIDs.contains($0.id) && $0.action.isActionable }
    }

    public var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Lifecycle & Scan

    public func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        currentProbeLabel = ""
    }

    public func startScan(host: ZtatCleanerHost? = nil) {
        scanTask?.cancel()
        isScanning = true
        activeSpacePlan = nil
        selectedItemIDs.removeAll()

        let settings = CleanerSettingsStore.shared
        let includeExternal = settings.sysDataScanExternalVolumes
        let hiddenIDs = settings.sysDataHiddenIDs
        let probes = SystemDataProbes.primaryProbes
        totalProbes = probes.count + 1 // +1 for claim-aware catch-all
        completedProbes = 0
        currentProbeLabel = ZtatL10n.tr("正在准备磁盘透视…", "Preparing System Data scan…")
        let ctx = SystemDataScanContext(includeExternalVolumes: includeExternal)

        scanTask = Task { [weak self] in
            guard let self else { return }
            let initialMeta = await Task.detached(priority: .utility) {
                (SystemDataDiskWalker.volumeOverview(), SystemDataDiskWalker.hasFullDiskAccess())
            }.value
            if Task.isCancelled {
                self.isScanning = false
                return
            }
            self.volumeOverview = initialMeta.0
            self.hasFullDiskAccess = initialMeta.1
            self.didLoadInitialOverview = true

            var collectedItems: [SystemDataItem] = []
            var claimedPaths = Set<String>()

            await withTaskGroup(of: (String, SystemDataProbeOutput).self) { group in
                for probe in probes {
                    group.addTask {
                        let result = await probe.run(ctx)
                        return (probe.label, result)
                    }
                }
                for await (label, output) in group {
                    if Task.isCancelled { break }
                    collectedItems.append(contentsOf: output.items)
                    claimedPaths.formUnion(output.claimedPaths)
                    self.completedProbes += 1
                    self.currentProbeLabel = label
                }
            }

            if Task.isCancelled {
                self.isScanning = false
                return
            }

            self.currentProbeLabel = ZtatL10n.tr("其他大型数据目录", "Other Large Folders")
            let catchAll = await SystemDataProbes.scanClaimAwareLargeFolders(ctx, claimedPaths: claimedPaths)
            if Task.isCancelled {
                self.isScanning = false
                return
            }
            collectedItems.append(contentsOf: catchAll.items)
            self.completedProbes = self.totalProbes

            let visibleItems = collectedItems
                .filter { !hiddenIDs.contains($0.id) }
                .sorted { $0.bytes > $1.bytes }

            let postMeta = await Task.detached(priority: .utility) {
                let ov = SystemDataDiskWalker.volumeOverview()
                let groups = Self.buildProjectGroups(from: visibleItems)
                return (ov, groups)
            }.value
            if Task.isCancelled {
                self.isScanning = false
                return
            }

            self.volumeOverview = postMeta.0
            self.applyScannedItems(visibleItems, prebuiltProjects: postMeta.1)
            self.isScanning = false
            self.hasScannedOnce = true
            self.currentProbeLabel = ""

            if settings.sysDataHistoryEnabled {
                var catTotals: [String: Int64] = [:]
                for item in visibleItems {
                    catTotals[item.category.rawValue, default: 0] += item.bytes
                }
                let record = SystemDataScanRecord(
                    totalBytes: self.totalMeasuredBytes,
                    safeBytes: self.totalSafeBytes,
                    reviewBytes: self.totalReviewBytes,
                    manualBytes: self.totalManualBytes,
                    categoryBytes: catTotals
                )
                SystemDataHistoryStore.shared.recordScan(record)
                self.reloadHistoryFromDisk()
            }

            host?.appendLog(
                section: "SystemData",
                message: ZtatL10n.tr(
                    "系统数据透视完成：发现 \(visibleItems.count) 项，总计 \(CleanerFormatters.bytes(self.totalMeasuredBytes))（安全可释放 \(CleanerFormatters.bytes(self.totalSafeBytes))）。",
                    "System Data scan complete: \(visibleItems.count) items, \(CleanerFormatters.bytes(self.totalMeasuredBytes)) total (\(CleanerFormatters.bytes(self.totalSafeBytes)) safe to free)."
                )
            )
        }
    }

    private func applyScannedItems(_ newItems: [SystemDataItem], prebuiltProjects: [ProjectFootprintGroup]? = nil) {
        items = newItems
        categorySummaries = SystemDataCategory.allCases.compactMap { cat in
            let subset = newItems.filter { $0.category == cat }.sorted { $0.bytes > $1.bytes }
            guard !subset.isEmpty else { return nil }
            let total = subset.reduce(0) { $0 + $1.bytes }
            let safe = subset.filter { $0.safety == .safe && $0.action.isActionable }.reduce(0) { $0 + $1.bytes }
            let review = subset.filter { $0.safety == .review && $0.action.isActionable }.reduce(0) { $0 + $1.bytes }
            let manual = subset.filter { $0.safety == .manual || !$0.action.isActionable }.reduce(0) { $0 + $1.bytes }
            return SystemDataCategorySummary(
                category: cat,
                items: subset,
                totalBytes: total,
                safeBytes: safe,
                reviewBytes: review,
                manualBytes: manual
            )
        }.sorted { $0.totalBytes > $1.totalBytes }

        if let prebuiltProjects {
            projectGroups = prebuiltProjects
        } else {
            // Preserve existing metadata without touching disk on MainActor
            let existingMeta = Dictionary(uniqueKeysWithValues: projectGroups.map { ($0.id, ($0.rootExists, $0.lastSourceModified)) })
            var byProject: [String: (root: URL, items: [SystemDataItem])] = [:]
            for item in newItems {
                guard let root = item.projectRoot else { continue }
                let key = root.standardizedFileURL.path
                var entry = byProject[key] ?? (root, [])
                entry.items.append(item)
                byProject[key] = entry
            }
            projectGroups = byProject.values.map { entry in
                let key = entry.root.standardizedFileURL.path
                let cached = existingMeta[key]
                return ProjectFootprintGroup(
                    id: key,
                    projectName: entry.root.lastPathComponent,
                    projectRoot: entry.root,
                    rootExists: cached?.0 ?? true,
                    lastSourceModified: cached?.1 ?? entry.items.compactMap(\.lastModified).max(),
                    items: entry.items.sorted { $0.bytes > $1.bytes }
                )
            }.sorted { $0.totalBytes > $1.totalBytes }
        }

        returnedItems = SystemDataHistoryStore.shared.detectReturnedItems(currentItems: newItems)
        weekDeltaBytes = SystemDataHistoryStore.shared.weekOverWeekDelta(currentTotal: totalMeasuredBytes)
    }

    nonisolated private static func buildProjectGroups(from newItems: [SystemDataItem]) -> [ProjectFootprintGroup] {
        var byProject: [String: (root: URL, items: [SystemDataItem])] = [:]
        for item in newItems {
            guard let root = item.projectRoot else { continue }
            let key = root.standardizedFileURL.path
            var entry = byProject[key] ?? (root, [])
            entry.items.append(item)
            byProject[key] = entry
        }

        let fm = FileManager.default
        return byProject.values.map { entry in
            let exists = fm.fileExists(atPath: entry.root.path)
            let lastMod = Self.projectActivityDate(at: entry.root) ?? entry.items.compactMap(\.lastModified).max()
            return ProjectFootprintGroup(
                id: entry.root.standardizedFileURL.path,
                projectName: entry.root.lastPathComponent,
                projectRoot: entry.root,
                rootExists: exists,
                lastSourceModified: lastMod,
                items: entry.items.sorted { $0.bytes > $1.bytes }
            )
        }.sorted { $0.totalBytes > $1.totalBytes }
    }

    nonisolated private static func projectActivityDate(at root: URL) -> Date? {
        let candidates = [
            root.appendingPathComponent(".git/index"),
            root.appendingPathComponent(".git/HEAD"),
            root
        ]
        for url in candidates {
            if let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                return mod
            }
        }
        return nil
    }

    public func reloadHistoryFromDisk() {
        let snap = SystemDataHistoryStore.shared.currentSnapshot()
        scanHistory = snap.scans
        returnedItems = SystemDataHistoryStore.shared.detectReturnedItems(currentItems: items)
        weekDeltaBytes = SystemDataHistoryStore.shared.weekOverWeekDelta(currentTotal: totalMeasuredBytes)
    }

    public func clearHistory() {
        SystemDataHistoryStore.shared.clearAll()
        reloadHistoryFromDisk()
    }

    // MARK: - Selection & Space Plan

    public func toggleSelection(for item: SystemDataItem) {
        guard item.action.isActionable else { return }
        activeSpacePlan = nil
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    public func selectAllSafe() {
        activeSpacePlan = nil
        selectedItemIDs = Set(items.filter { $0.safety == .safe && $0.action.isActionable }.map(\.id))
    }

    public func clearSelection() {
        activeSpacePlan = nil
        selectedItemIDs.removeAll()
    }

    public func applySpacePlan(targetGigabytes: Int) {
        let targetBytes = Int64(targetGigabytes) * 1_000_000_000
        let proposal = SpacePlanBuilder.build(items: items, targetBytes: targetBytes)
        activeSpacePlan = proposal
        selectedItemIDs = proposal.selectedIDs
    }

    public func selectProjectArtifacts(_ group: ProjectFootprintGroup) {
        activeSpacePlan = nil
        for item in group.items where item.action.isActionable {
            selectedItemIDs.insert(item.id)
        }
    }

    public func hideItem(_ item: SystemDataItem) {
        CleanerSettingsStore.shared.sysDataHiddenIDs.insert(item.id)
        selectedItemIDs.remove(item.id)
        applyScannedItems(items.filter { $0.id != item.id })
    }

    // MARK: - Touch ID / LocalAuthentication

    public func authenticateIfNeeded() async -> Bool {
        guard CleanerSettingsStore.shared.sysDataRequireAuth else { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return true
        }
        let reason = ZtatL10n.tr("验证身份以清理选中的系统数据项", "Authenticate to reclaim selected System Data items")
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Reclaim Execution

    public func reclaimSelected(host: ZtatCleanerHost) async {
        guard !isReclaiming else { return }
        let targets = selectedItems
        guard !targets.isEmpty else { return }

        isReclaiming = true
        defer { isReclaiming = false }

        if !(await authenticateIfNeeded()) {
            host.showBanner(ZtatL10n.tr("身份验证已取消，未执行清理。", "Authentication cancelled; nothing was removed."), isError: true)
            return
        }

        var totalFreed: Int64 = 0
        var succeededIDs = Set<String>()
        var failures: [(title: String, reason: String)] = []
        var deletionRecords: [SystemDataDeletionRecord] = []

        for item in targets {
            switch item.action {
            case .manual:
                continue

            case .trashPaths(let urls):
                let outcome = await SafeDeletionEngine.shared.trashItems(
                    urls: urls,
                    bundleLabel: "SysData_\(item.category.rawValue)",
                    sourceModule: "sysdata",
                    onLog: { msg, isErr in
                        Task { @MainActor in host.appendLog(section: "SystemData", message: msg, isError: isErr) }
                    }
                )
                if outcome.succeededCount > 0 {
                    let freed = max(outcome.freedBytes, outcome.failedItems.isEmpty ? item.bytes : 0)
                    totalFreed += freed
                    if outcome.failedItems.isEmpty {
                        succeededIDs.insert(item.id)
                    }
                    deletionRecords.append(SystemDataDeletionRecord(
                        itemID: item.id, title: item.title, path: item.path?.standardizedFileURL.path, bytesFreed: freed
                    ))
                }
                if let firstErr = outcome.failedItems.first {
                    failures.append((item.title, firstErr.reason))
                }

            case .pruneOlderThan(let directory, let days):
                let staleURLs = await Task.detached(priority: .utility) {
                    Self.collectStaleRegularFileURLs(in: directory, olderThanDays: days)
                }.value
                guard !staleURLs.isEmpty else {
                    succeededIDs.insert(item.id)
                    continue
                }
                let outcome = await SafeDeletionEngine.shared.trashItems(
                    urls: staleURLs,
                    bundleLabel: "SysData_Temp",
                    sourceModule: "sysdata",
                    onLog: { msg, isErr in
                        Task { @MainActor in host.appendLog(section: "SystemData", message: msg, isError: isErr) }
                    }
                )
                totalFreed += outcome.freedBytes
                if outcome.succeededCount > 0 {
                    succeededIDs.insert(item.id)
                    deletionRecords.append(SystemDataDeletionRecord(
                        itemID: item.id, title: item.title, path: directory.standardizedFileURL.path, bytesFreed: outcome.freedBytes
                    ))
                }
                if let firstErr = outcome.failedItems.first {
                    failures.append((item.title, firstErr.reason))
                }

            case .toolCommand(let executable, let arguments, let display):
                host.appendLog(section: "SystemData", message: "Running: \(display)")
                if let out = try? await CleanerProcessRunner.runAsync(executable, arguments, timeout: 60), out.succeeded {
                    totalFreed += item.bytes
                    succeededIDs.insert(item.id)
                    deletionRecords.append(SystemDataDeletionRecord(
                        itemID: item.id, title: item.title, path: item.path?.standardizedFileURL.path, bytesFreed: item.bytes
                    ))
                    if !out.combinedTrimmed.isEmpty {
                        host.appendLog(section: "SystemData", message: out.combinedTrimmed)
                    }
                } else {
                    let msg = ZtatL10n.tr("命令执行失败：\(display)", "Command failed: \(display)")
                    failures.append((item.title, msg))
                    host.appendLog(section: "SystemData", message: msg, isError: true)
                }

            case .thinSnapshots(let bytes):
                let bounded = max(1_048_576, bytes)
                if let out = try? await CleanerProcessRunner.runAsync("/usr/bin/tmutil", ["thinlocalsnapshots", "/", "\(bounded)", "4"], timeout: 60),
                   out.succeeded {
                    totalFreed += item.bytes
                    succeededIDs.insert(item.id)
                    deletionRecords.append(SystemDataDeletionRecord(
                        itemID: item.id, title: item.title, path: nil, bytesFreed: item.bytes
                    ))
                } else {
                    failures.append((item.title, ZtatL10n.tr("本地快照瘦身失败（可能需要管理员权限）。", "Snapshot thinning failed (may require admin privileges).")))
                }

            case .deleteSnapshot(let dateStamp):
                guard SystemDataProbes.isValidSnapshotStamp(dateStamp) else {
                    failures.append((item.title, ZtatL10n.tr("无效的快照时间戳。", "Invalid snapshot date stamp.")))
                    continue
                }
                if let out = try? await CleanerProcessRunner.runAsync("/usr/bin/tmutil", ["deletelocalsnapshots", dateStamp], timeout: 30),
                   out.succeeded {
                    totalFreed += item.bytes
                    succeededIDs.insert(item.id)
                    deletionRecords.append(SystemDataDeletionRecord(
                        itemID: item.id, title: item.title, path: nil, bytesFreed: item.bytes
                    ))
                } else {
                    failures.append((item.title, ZtatL10n.tr("删除快照失败：\(dateStamp)", "Failed to delete snapshot \(dateStamp).")))
                }
            }
        }

        if CleanerSettingsStore.shared.sysDataHistoryEnabled && !deletionRecords.isEmpty {
            SystemDataHistoryStore.shared.recordDeletions(deletionRecords)
            reloadHistoryFromDisk()
        }

        selectedItemIDs.subtract(succeededIDs)
        activeSpacePlan = nil
        volumeOverview = SystemDataDiskWalker.volumeOverview()
        applyScannedItems(items.filter { !succeededIDs.contains($0.id) })

        if failures.isEmpty {
            host.showBanner(ZtatL10n.tr(
                "已清理 \(succeededIDs.count) 项系统数据，预计释放 \(CleanerFormatters.bytes(totalFreed))（文件类均已移入废纸篓可还原）。",
                "Reclaimed \(succeededIDs.count) items (~\(CleanerFormatters.bytes(totalFreed))); file items are restorable from Delete History."
            ), isError: false)
        } else {
            host.showBanner(ZtatL10n.tr(
                "已清理 \(succeededIDs.count) 项，\(failures.count) 项失败：\(failures[0].reason)",
                "Reclaimed \(succeededIDs.count) items, \(failures.count) failed: \(failures[0].reason)"
            ), isError: true)
        }
    }

    public func compressItem(_ item: SystemDataItem, host: ZtatCleanerHost) async {
        guard let url = item.path, item.isCompressible else { return }
        isCompressingID = item.id
        defer { isCompressingID = nil }

        let result = await SystemDataCompressionEngine.compressDirectory(at: url)
        host.appendLog(section: "SystemData", message: "\(item.title): \(result.message)", isError: !result.succeeded)
        host.showBanner(result.message, isError: !result.succeeded)
        if result.succeeded {
            volumeOverview = SystemDataDiskWalker.volumeOverview()
            let updated = items.map { existing -> SystemDataItem in
                guard existing.id == item.id else { return existing }
                return SystemDataItem(
                    id: existing.id,
                    category: existing.category,
                    title: existing.title,
                    subtitle: existing.subtitle,
                    path: existing.path,
                    bytes: result.compressedBytes,
                    lastModified: existing.lastModified,
                    safety: existing.safety,
                    recovery: existing.recovery,
                    action: existing.action,
                    projectRoot: existing.projectRoot,
                    isStalled: existing.isStalled,
                    isCompressible: false,
                    detailNote: existing.detailNote
                )
            }
            applyScannedItems(updated)
        }
    }

    nonisolated private static func collectStaleRegularFileURLs(in dir: URL, olderThanDays days: Int) -> [URL] {
        let fm = FileManager.default
        let cleanDir = dir.standardizedFileURL
        guard (try? fm.destinationOfSymbolicLink(atPath: cleanDir.path)) == nil else {
            return []
        }
        let startVolume = SystemDataDiskWalker.volumeIdentifier(of: cleanDir)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .volumeIdentifierKey]
        guard let enumerator = fm.enumerator(at: cleanDir, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return []
        }
        var urls: [URL] = []
        var ticks = 0
        for case let file as URL in enumerator {
            ticks += 1
            if ticks & 0xFF == 0, Task.isCancelled { break }
            if urls.count >= 5000 { break }
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
            if SafePathGuard.rejectionReason(for: file) == nil {
                urls.append(file)
            }
        }
        return urls
    }
}
