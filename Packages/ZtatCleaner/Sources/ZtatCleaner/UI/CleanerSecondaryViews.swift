// SPDX-License-Identifier: GPL-3.0-or-later
// Remaining 9 native SwiftUI views for ZtatCleaner:
// Orphans, Lipo, Developer, Packages (PKG/Receipts), Plugins (18 categories),
// Services (LaunchAgents/Daemons), File Search, Delete History, and Cleaner Settings.

import AppKit
import SwiftUI
import ZtatCore

// MARK: - 1. Orphaned / Zombie Files View

struct CleanerOrphansView: View {
    @ObservedObject var host: ZtatCleanerHost
    @ObservedObject private var settings = CleanerSettingsStore.shared
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    @State private var orphans: [OrphanedFileItem] = []
    @State private var isScanning = false
    @State private var progressText = ""
    @State private var searchText = ""
    @State private var scanTask: Task<Void, Never>?
    @State private var linkingItem: OrphanedFileItem? = nil

    private var filtered: [OrphanedFileItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return orphans }
        return orphans.filter { $0.name.lowercased().contains(q) || $0.displayPath.lowercased().contains(q) }
    }

    private var selectedItems: [OrphanedFileItem] {
        orphans.filter(\.isSelected)
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        let _ = l10n.revision
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ZtatL10n.tr("孤立残留文件扫描", "Orphaned / Zombie Files"))
                        .font(.headline)
                    Text(ZtatL10n.tr(
                        "反向扫描 22 个 macOS 资源库目录，定位已卸载软件遗留的数据；默认全不勾选，支持排除或关联至现有应用。",
                        "Scans 22 macOS Library paths for leftover files not matched to installed apps. Starts unchecked for safety."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if isScanning {
                    Button(ZtatL10n.tr("停止", "Stop")) {
                        scanTask?.cancel()
                        isScanning = false
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        startScan()
                    } label: {
                        Label(ZtatL10n.tr("开始扫描", "Scan Orphans"), systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)

            Divider()

            if isScanning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(progressText.isEmpty ? ZtatL10n.tr("正在扫描资源库…", "Scanning Library folders…") : progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if orphans.isEmpty {
                ContentUnavailableView(
                    ZtatL10n.tr("点击“开始扫描”检测孤立残留", "Click Scan to Find Orphaned Files"),
                    systemImage: "doc.badge.ellipsis",
                    description: Text(ZtatL10n.tr("自动保护 Apple 系统、已安装应用及源代码仓库。", "Automatically protects Apple system files, installed apps, and source repositories."))
                )
            } else {
                HStack(spacing: 8) {
                    TextField(ZtatL10n.tr("筛选孤立文件…", "Filter orphans…"), text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(maxWidth: 260)
                    Spacer()
                    Button(ZtatL10n.tr("全选", "Select All")) {
                        for idx in orphans.indices { orphans[idx].isSelected = true }
                    }
                    .controlSize(.small)
                    Button(ZtatL10n.tr("取消全选", "Deselect")) {
                        for idx in orphans.indices { orphans[idx].isSelected = false }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                List {
                    ForEach(filtered) { item in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { item.isSelected },
                                set: { val in
                                    if let idx = orphans.firstIndex(where: { $0.id == item.id }) {
                                        orphans[idx].isSelected = val
                                    }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)

                            Image(systemName: item.category.symbolName)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text("\(item.displayPath)  ·  \(item.category.title)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(CleanerFormatters.bytes(item.size))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button(ZtatL10n.tr("在访达中显示", "Reveal in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            }
                            Button(ZtatL10n.tr("永久排除此路径", "Exclude Permanently")) {
                                settings.addOrphanExclusion(item.url.path)
                                orphans.removeAll { $0.id == item.id }
                            }
                            Button(ZtatL10n.tr("关联到已安装应用…", "Link to Installed App…")) {
                                linkingItem = item
                            }
                        }
                    }
                }
                .listStyle(.inset)

                Divider()

                HStack {
                    Text(ZtatL10n.tr(
                        "已选 \(selectedItems.count) / \(orphans.count) 项 · 共 \(CleanerFormatters.bytes(selectedBytes))",
                        "Selected \(selectedItems.count) / \(orphans.count) · \(CleanerFormatters.bytes(selectedBytes))"
                    ))
                    .font(.callout.monospacedDigit())
                    Spacer()
                    Button(ZtatL10n.tr("排除选中", "Exclude Selected")) {
                        for it in selectedItems { settings.addOrphanExclusion(it.url.path) }
                        let ids = Set(selectedItems.map(\.id))
                        orphans.removeAll { ids.contains($0.id) }
                    }
                    .disabled(selectedItems.isEmpty)

                    Button(ZtatL10n.tr("移入废纸篓", "Move to Trash"), role: .destructive) {
                        trashSelectedOrphans()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selectedItems.isEmpty)
                }
                .padding(14)
            }
        }
        .sheet(item: $linkingItem) { orphan in
            LinkOrphanToAppSheet(orphan: orphan, apps: host.installedApps) { chosenApp in
                settings.linkOrphan(orphan.url.path, toAppPath: chosenApp.id)
                orphans.removeAll { $0.id == orphan.id }
                host.showBanner(ZtatL10n.tr("已将 \(orphan.name) 关联至 \(chosenApp.name)。", "Linked \(orphan.name) to \(chosenApp.name)."), isError: false)
            }
        }
        .onAppear { host.ensureAppsLoaded() }
        .onDisappear { scanTask?.cancel() }
    }

    private func startScan() {
        scanTask?.cancel()
        isScanning = true
        scanTask = Task {
            if !host.hasLoadedAppsOnce {
                await host.refreshInstalledApps()
            }
            let apps = host.installedApps
            let exclusions = settings.orphanExclusions
            let found = await OrphanScannerEngine.shared.scanOrphans(
                installedApps: apps,
                exclusions: exclusions,
                onProgress: { step, total in
                    Task { @MainActor in
                        progressText = ZtatL10n.tr("正在扫描资源库目录 \(step)/\(total)…", "Scanning Library \(step)/\(total)…")
                    }
                }
            )
            await MainActor.run {
                orphans = found
                isScanning = false
                host.appendLog(section: "Orphans", message: "Found \(found.count) orphaned candidates.")
            }
        }
    }

    private func trashSelectedOrphans() {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        Task {
            let outcome = await SafeDeletionEngine.shared.trashItems(
                urls: chosen.map(\.url),
                bundleLabel: "OrphanedFiles_\(chosen.count)",
                sourceModule: "orphans"
            )
            await MainActor.run {
                let ids = Set(chosen.map(\.id))
                orphans.removeAll { ids.contains($0.id) }
                host.showBanner(ZtatL10n.tr(
                    "已清理孤立残留 \(outcome.succeededCount) 项，释放 \(CleanerFormatters.bytes(outcome.freedBytes))。",
                    "Moved \(outcome.succeededCount) orphan items (\(CleanerFormatters.bytes(outcome.freedBytes))) to Trash."
                ), isError: !outcome.failedItems.isEmpty)
            }
        }
    }
}

private struct LinkOrphanToAppSheet: View {
    let orphan: OrphanedFileItem
    let apps: [InstalledAppEntry]
    let onLink: (InstalledAppEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(ZtatL10n.tr("将“\(orphan.name)”关联到应用", "Link \"\(orphan.name)\" to App")).font(.headline)
                Spacer()
                Button(ZtatL10n.tr("取消", "Cancel")) { dismiss() }
            }
            .padding()
            TextField(ZtatL10n.tr("搜索已安装应用…", "Search installed apps…"), text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)
            List(apps.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { app in
                Button {
                    onLink(app)
                    dismiss()
                } label: {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable()
                            .frame(width: 22, height: 22)
                        Text(app.name)
                        Spacer()
                        Text(app.bundleIdentifier).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 460, height: 380)
    }
}

// MARK: - 2. App Lipo (Universal Binary Architecture Slimmer) View

struct CleanerLipoView: View {
    @ObservedObject var host: ZtatCleanerHost
    @ObservedObject private var settings = CleanerSettingsStore.shared
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    @State private var analyses: [LipoAppAnalysis] = []
    @State private var selectedIDs: Set<String> = []
    @State private var isAnalyzing = false
    @State private var isThinning = false
    @State private var searchText = ""

    private var visibleAnalyses: [LipoAppAnalysis] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return analyses.filter { item in
            if settings.lipoExcludedAppPaths.contains(item.id) { return false }
            if !settings.lipoShowZeroSavings && item.reclaimableBytes == 0 { return false }
            if settings.lipoMinSavings1MB && item.reclaimableBytes < 1_048_576 { return false }
            if !q.isEmpty && !item.app.name.lowercased().contains(q) { return false }
            return true
        }
    }

    private var selectedReclaimable: Int64 {
        visibleAnalyses.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.reclaimableBytes }
    }

    var body: some View {
        let _ = l10n.revision
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ZtatL10n.tr("通用二进制架构瘦身 (App Lipo)", "Universal Binary Slimmer (App Lipo)"))
                        .font(.headline)
                    Text(ZtatL10n.tr(
                        "纯 Swift 解析 Mach-O 32/64 位 FAT 二进制（无需 Xcode lipo），仅保留当前 \(AppArchitecture.hostNative.badgeLabel) 切片。累计已节省 \(CleanerFormatters.bytes(settings.lipoTotalSavedBytes))。",
                        "Pure-Swift Mach-O 32/64-bit FAT slicer (no Xcode lipo needed), keeping \(AppArchitecture.hostNative.badgeLabel) slices only. Total saved: \(CleanerFormatters.bytes(settings.lipoTotalSavedBytes))."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    analyzeUniversalApps()
                } label: {
                    Label(ZtatL10n.tr("分析可瘦身应用", "Analyze Universal Apps"), systemImage: "scissors")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAnalyzing || isThinning)
            }
            .padding(14)

            HStack(spacing: 12) {
                TextField(ZtatL10n.tr("搜索通用应用…", "Search universal apps…"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                Toggle(ZtatL10n.tr("仅显示 ≥1 MB", "≥1 MB only"), isOn: $settings.lipoMinSavings1MB)
                    .controlSize(.small)
                Toggle(ZtatL10n.tr("瘦身时同步裁剪多余语言包", "Also prune unused languages"), isOn: $settings.lipoPruneTranslations)
                    .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            Divider()

            if isAnalyzing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(ZtatL10n.tr("正在解析应用内 Mach-O 通用二进制切片…", "Inspecting Universal Mach-O binary slices…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleAnalyses.isEmpty {
                ContentUnavailableView(
                    ZtatL10n.tr("点击“分析可瘦身应用”计算可回收空间", "Click Analyze to Preview Reclaimable Space"),
                    systemImage: "scissors",
                    description: Text(ZtatL10n.tr("瘦身采用原子替换并保留原文件权限；自动跳过 SIP 受保护应用。", "Atomic slice replacement preserves file permissions and skips SIP-protected bundles."))
                )
            } else {
                List(visibleAnalyses) { item in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { selectedIDs.contains(item.id) },
                            set: { on in
                                if on { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(item.isSIPProtected)

                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.app.url.path))
                            .resizable()
                            .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.app.name).font(.system(size: 12.5, weight: .semibold))
                                CleanerMicroBadge(text: "\(item.fatBinaryCount) FAT", color: .purple)
                                if item.isAppStoreSealed {
                                    CleanerMicroBadge(text: "App Store", color: .orange)
                                }
                            }
                            Text(item.detailNote ?? ZtatL10n.tr(
                                "原体积 \(CleanerFormatters.bytes(item.app.bundleSize)) · 预计节省 \(String(format: "%.1f%%", item.savingsPercent))",
                                "Bundle \(CleanerFormatters.bytes(item.app.bundleSize)) · Est. \(String(format: "%.1f%%", item.savingsPercent)) saved"
                            ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text("-\(CleanerFormatters.bytes(item.reclaimableBytes))")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.green)
                    }
                    .contextMenu {
                        Button(ZtatL10n.tr("从瘦身列表中排除", "Exclude from Lipo")) {
                            settings.lipoExcludedAppPaths.insert(item.id)
                            selectedIDs.remove(item.id)
                        }
                    }
                }
                .listStyle(.inset)

                Divider()

                HStack {
                    Text(ZtatL10n.tr(
                        "已选 \(selectedIDs.count) 个应用 · 预计释放 \(CleanerFormatters.bytes(selectedReclaimable))",
                        "Selected \(selectedIDs.count) apps · Est. \(CleanerFormatters.bytes(selectedReclaimable))"
                    ))
                    .font(.callout.monospacedDigit())
                    Spacer()
                    Button(ZtatL10n.tr("执行架构瘦身", "Thin Selected Apps")) {
                        thinSelectedApps()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIDs.isEmpty || isThinning)
                }
                .padding(14)
            }
        }
        .onAppear { host.ensureAppsLoaded() }
    }

    private func analyzeUniversalApps() {
        isAnalyzing = true
        Task {
            if !host.hasLoadedAppsOnce {
                await host.refreshInstalledApps()
            }
            let universals = host.installedApps.filter { $0.architecture == .universal }
            var out: [LipoAppAnalysis] = []
            for app in universals {
                let res = await MachOLipoEngine.shared.analyzeApp(app)
                out.append(res)
            }
            out.sort { $0.reclaimableBytes > $1.reclaimableBytes }
            await MainActor.run {
                analyses = out
                isAnalyzing = false
            }
        }
    }

    private func thinSelectedApps() {
        let targets = visibleAnalyses.filter { selectedIDs.contains($0.id) }.map(\.app)
        guard !targets.isEmpty else { return }
        isThinning = true
        Task {
            var totalReclaimed: Int64 = 0
            var failures: [(name: String, reason: String)] = []
            var signatureWarning: String?
            for app in targets {
                let res = await MachOLipoEngine.shared.thinApp(
                    app,
                    alsoPruneLanguages: settings.lipoPruneTranslations,
                    keepLanguageCodes: settings.keepLanguageCodes
                )
                totalReclaimed += res.reclaimedBytes + res.languagesPrunedBytes
                if let err = res.errorMessage {
                    failures.append((app.name, err))
                    await MainActor.run {
                        host.appendLog(section: "Lipo", message: "\(app.name): \(err)", isError: true)
                    }
                }
                if let warning = res.codeSignatureWarning {
                    signatureWarning = warning
                    await MainActor.run {
                        host.appendLog(section: "Lipo", message: "\(app.name): \(warning)", isError: false)
                    }
                }
            }
            await host.refreshInstalledApps()
            await MainActor.run {
                isThinning = false
                selectedIDs.removeAll()
                if failures.isEmpty {
                    var message = ZtatL10n.tr(
                        "批量瘦身完成，共释放 \(CleanerFormatters.bytes(totalReclaimed))。",
                        "Batch thinning complete: saved \(CleanerFormatters.bytes(totalReclaimed))."
                    )
                    if let signatureWarning { message += " " + signatureWarning }
                    host.showBanner(message, isError: false)
                } else {
                    let names = failures.map(\.name).joined(separator: ", ")
                    host.showBanner(ZtatL10n.tr(
                        "批量瘦身完成，共释放 \(CleanerFormatters.bytes(totalReclaimed))；\(failures.count) 个应用失败（\(names)）：\(failures[0].reason)",
                        "Batch thinning saved \(CleanerFormatters.bytes(totalReclaimed)); \(failures.count) app(s) failed (\(names)): \(failures[0].reason)"
                    ), isError: true)
                }
            }
            analyzeUniversalApps()
        }
    }
}

// MARK: - 3. Developer Environment Cleaner View

struct CleanerDeveloperView: View {
    @ObservedObject var host: ZtatCleanerHost
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    private enum DevSubTab: String, CaseIterable, Identifiable {
        case caches, workspaces, pip
        var id: String { rawValue }
        var title: String {
            switch self {
            case .caches: return ZtatL10n.tr("26 项工具链缓存", "Toolchain Caches")
            case .workspaces: return ZtatL10n.tr("IDE 孤立工作区", "IDE Orphan Workspaces")
            case .pip: return ZtatL10n.tr("Python Pip 包管理", "Pip Packages")
            }
        }
    }

    @State private var subTab: DevSubTab = .caches
    @State private var groups: [DevToolchainGroup] = []
    @State private var workspaces: [OrphanedIDEWorkspace] = []
    @State private var pipPackages: [PipPackageItem] = []
    @State private var pythonPath: String? = nil
    @State private var pipError: String? = nil
    @State private var isLoading = false

    private var selectedDevItems: [DevPathItem] {
        groups.flatMap(\.items).filter(\.isSelected)
    }

    var body: some View {
        let _ = l10n.revision
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $subTab) {
                    ForEach(DevSubTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Spacer()
                Button {
                    refreshActiveTab()
                } label: {
                    Label(ZtatL10n.tr("重新扫描", "Rescan"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(isLoading)
            }
            .padding(14)

            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch subTab {
                case .caches: devCachesContent
                case .workspaces: ideWorkspacesContent
                case .pip: pipPackagesContent
                }
            }
        }
        .onAppear {
            if groups.isEmpty { refreshActiveTab() }
        }
        .onChange(of: subTab) { _, _ in
            refreshActiveTab()
        }
    }

    @ViewBuilder
    private var devCachesContent: some View {
        if groups.isEmpty {
            ContentUnavailableView(ZtatL10n.tr("未发现可清理的开发环境缓存", "No Developer Caches Detected"), systemImage: "hammer")
        } else {
            List {
                ForEach(groups.indices, id: \.self) { gIdx in
                    let group = groups[gIdx]
                    Section {
                        ForEach(group.items.indices, id: \.self) { iIdx in
                            let item = group.items[iIdx]
                            HStack(spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { groups[gIdx].items[iIdx].isSelected },
                                    set: { val in
                                        var copy = groups[gIdx].items
                                        copy[iIdx].isSelected = val
                                        groups[gIdx] = DevToolchainGroup(id: group.id, name: group.name, symbolName: group.symbolName, items: copy)
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.checkbox)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label).font(.system(size: 12.5, weight: .medium))
                                    Text(item.displayPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(CleanerFormatters.bytes(item.size))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button(ZtatL10n.tr("在访达中显示", "Reveal in Finder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Label(group.name, systemImage: group.symbolName).font(.caption.weight(.semibold))
                            Spacer()
                            Text(CleanerFormatters.bytes(group.totalSize)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                let bytes = selectedDevItems.reduce(Int64(0)) { $0 + $1.size }
                Text(ZtatL10n.tr("已选 \(selectedDevItems.count) 项 · \(CleanerFormatters.bytes(bytes))", "Selected \(selectedDevItems.count) · \(CleanerFormatters.bytes(bytes))"))
                    .font(.callout.monospacedDigit())
                Spacer()
                Button(ZtatL10n.tr("仅清空目录内容", "Delete Contents Only")) {
                    cleanSelectedDev(contentsOnly: true)
                }
                .disabled(selectedDevItems.isEmpty)
                Button(ZtatL10n.tr("移入废纸篓（含目录）", "Delete Folders"), role: .destructive) {
                    cleanSelectedDev(contentsOnly: false)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedDevItems.isEmpty)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var ideWorkspacesContent: some View {
        if workspaces.isEmpty {
            ContentUnavailableView(
                ZtatL10n.tr("没有失效的 IDE 工作区缓存", "No Orphaned IDE Workspaces Found"),
                systemImage: "checkmark.circle",
                description: Text(ZtatL10n.tr("已检查 VS Code / Cursor / Zed 的 workspaceStorage。", "Checked VS Code, Cursor, and Zed workspaceStorage."))
            )
        } else {
            List {
                ForEach($workspaces) { $ws in
                    HStack {
                        Toggle("", isOn: $ws.isSelected).labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                CleanerMicroBadge(text: ws.ideName, color: .blue)
                                Text(ws.missingProjectPath).font(.caption).lineLimit(1)
                            }
                            Text(ws.storageURL.lastPathComponent).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(CleanerFormatters.bytes(ws.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                let chosen = workspaces.filter(\.isSelected)
                Text(ZtatL10n.tr("发现 \(workspaces.count) 个已失效项目工作区", "\(workspaces.count) orphaned workspaces"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(ZtatL10n.tr("全部勾选", "Select All")) {
                    for i in workspaces.indices { workspaces[i].isSelected = true }
                }
                Button(ZtatL10n.tr("清理选中", "Clean Selected"), role: .destructive) {
                    Task {
                        let res = await SafeDeletionEngine.shared.trashItems(
                            urls: chosen.map(\.storageURL),
                            bundleLabel: "IDE_OrphanWorkspaces",
                            sourceModule: "developer"
                        )
                        await MainActor.run {
                            host.showBanner(ZtatL10n.tr("已清理 \(res.succeededCount) 个孤立工作区，释放 \(CleanerFormatters.bytes(res.freedBytes))。", "Cleaned \(res.succeededCount) workspaces (\(CleanerFormatters.bytes(res.freedBytes)))."), isError: false)
                        }
                        refreshActiveTab()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(chosen.isEmpty)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var pipPackagesContent: some View {
        if let err = pipError {
            ContentUnavailableView(ZtatL10n.tr("无法读取 Pip 包列表", "Unable to List Pip Packages"), systemImage: "exclamationmark.triangle", description: Text(err))
        } else if pipPackages.isEmpty {
            ContentUnavailableView(ZtatL10n.tr("暂无已安装 Pip 包", "No Pip Packages Found"), systemImage: "shippingbox")
        } else {
            VStack(spacing: 0) {
                if let py = pythonPath {
                    HStack {
                        Text("Python: \(py)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                List {
                    ForEach($pipPackages) { $pkg in
                        HStack {
                            Toggle("", isOn: $pkg.isSelected).labelsHidden().toggleStyle(.checkbox)
                            Text(pkg.name).font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            Text(pkg.version).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
                Divider()
                HStack {
                    let chosen = pipPackages.filter(\.isSelected).map(\.name)
                    Text(ZtatL10n.tr("共 \(pipPackages.count) 个包 · 已选 \(chosen.count)", "\(pipPackages.count) packages · \(chosen.count) selected"))
                        .font(.caption)
                    Spacer()
                    Button(ZtatL10n.tr("卸载选中 Pip 包", "Uninstall Selected"), role: .destructive) {
                        Task {
                            let (ok, out) = await DevCleanerEngine.shared.uninstallPipPackages(chosen)
                            await MainActor.run {
                                host.showBanner(ok ? ZtatL10n.tr("已卸载选中的 Pip 包。", "Uninstalled selected pip packages.") : out, isError: !ok)
                            }
                            refreshActiveTab()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(chosen.isEmpty)
                }
                .padding(14)
            }
        }
    }

    private func refreshActiveTab() {
        isLoading = true
        Task {
            switch subTab {
            case .caches:
                let g = await DevCleanerEngine.shared.scanToolchains()
                await MainActor.run { groups = g; isLoading = false }
            case .workspaces:
                let w = await DevCleanerEngine.shared.scanOrphanedIDEWorkspaces()
                await MainActor.run { workspaces = w; isLoading = false }
            case .pip:
                let r = await DevCleanerEngine.shared.listPipPackages()
                await MainActor.run {
                    pythonPath = r.pythonPath
                    pipPackages = r.packages
                    pipError = r.error
                    isLoading = false
                }
            }
        }
    }

    private func cleanSelectedDev(contentsOnly: Bool) {
        let targets = selectedDevItems
        guard !targets.isEmpty else { return }
        Task {
            let res = await DevCleanerEngine.shared.cleanDevItems(targets, contentsOnly: contentsOnly)
            await MainActor.run {
                host.showBanner(ZtatL10n.tr(
                    "开发环境清理完成：\(res.succeededCount) 项，释放 \(CleanerFormatters.bytes(res.freedBytes))。",
                    "Cleaned \(res.succeededCount) dev items (\(CleanerFormatters.bytes(res.freedBytes)))."
                ), isError: !res.failedItems.isEmpty)
            }
            refreshActiveTab()
        }
    }
}

// MARK: - 4. PKG / Receipts Manager View

struct CleanerPackagesView: View {
    @ObservedObject var host: ZtatCleanerHost
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    @State private var receipts: [PackageReceiptItem] = []
    @State private var selectedReceipt: PackageReceiptItem? = nil
    @State private var bomEntries: [PackageBOMEntry] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var isLoadingBOM = false

    private var filteredReceipts: [PackageReceiptItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return receipts }
        return receipts.filter { $0.displayName.lowercased().contains(q) || $0.packageID.lowercased().contains(q) }
    }

    /// Selected, existing entries. A selected folder is dropped while it still contains an
    /// entry the user unchecked — trashing the folder would take that file with it.
    private var chosenBOMEntries: [PackageBOMEntry] {
        let keptPaths = bomEntries.filter { $0.exists && !$0.isSelected }.map(\.url.path)
        return bomEntries.filter { entry in
            guard entry.exists, entry.isSelected else { return false }
            guard entry.isDirectory else { return true }
            let prefix = entry.url.path + "/"
            return !keptPaths.contains { $0.hasPrefix(prefix) }
        }
    }

    var body: some View {
        let _ = l10n.revision
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField(ZtatL10n.tr("搜索安装包 ID…", "Search PKG ID…"), text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Button { loadReceipts() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                }
                .padding(10)
                Divider()
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredReceipts, selection: $selectedReceipt) { pkg in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pkg.displayName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            Text("\(pkg.packageID) · v\(pkg.version)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(pkg)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 230, idealWidth: 260, maxWidth: 360)

            VStack(spacing: 0) {
                if let pkg = selectedReceipt {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pkg.displayName).font(.headline)
                            Text("\(pkg.packageID) · v\(pkg.version) · Prefix: \(pkg.installPrefix)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(ZtatL10n.tr("仅遗忘收据", "Forget Receipt")) {
                            forgetSelectedReceipt(pkg)
                        }
                        .controlSize(.small)
                    }
                    .padding(14)
                    Divider()

                    if isLoadingBOM {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if bomEntries.isEmpty {
                        ContentUnavailableView(ZtatL10n.tr("收据中无可卸载的用户文件", "No Non-System BOM Files"), systemImage: "shippingbox")
                    } else {
                        List {
                            ForEach($bomEntries) { $entry in
                                HStack {
                                    Toggle("", isOn: $entry.isSelected).labelsHidden().toggleStyle(.checkbox)
                                        .disabled(!entry.exists)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.url.lastPathComponent)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(entry.exists ? .primary : .secondary)
                                        Text(entry.url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if entry.isDirectory {
                                        CleanerMicroBadge(text: ZtatL10n.tr("卸载后为空的文件夹", "Empty after uninstall"), color: .secondary)
                                    } else if entry.exists {
                                        Text(CleanerFormatters.bytes(entry.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    } else {
                                        CleanerMicroBadge(text: ZtatL10n.tr("已不存在", "Missing"), color: .secondary)
                                    }
                                }
                            }
                        }
                        .listStyle(.inset)

                        Divider()
                        HStack {
                            let chosen = chosenBOMEntries
                            Text(ZtatL10n.tr("已选 \(chosen.count) 个安装包文件", "\(chosen.count) installed files selected"))
                                .font(.caption)
                            Spacer()
                            Button(ZtatL10n.tr("卸载选中文件并移出收据", "Uninstall Package"), role: .destructive) {
                                uninstallPackage(pkg, entries: chosen)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(chosen.isEmpty)
                        }
                        .padding(14)
                    }
                } else {
                    ContentUnavailableView(
                        ZtatL10n.tr("选择左侧第三方 .pkg 安装包收据", "Select a Third-Party PKG Receipt"),
                        systemImage: "shippingbox.fill",
                        description: Text(ZtatL10n.tr("基于 pkgutil 收据仅列出安装包写入的文件，共享目录不会被预选。", "Lists only the files the package installed (via pkgutil); shared folders are never pre-selected."))
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if receipts.isEmpty { loadReceipts() } }
        .onChange(of: selectedReceipt) { _, newVal in
            guard let newVal else { bomEntries = []; return }
            isLoadingBOM = true
            Task {
                let entries = await PackageReceiptsEngine.shared.loadBOMEntries(for: newVal)
                await MainActor.run { bomEntries = entries; isLoadingBOM = false }
            }
        }
    }

    private func loadReceipts() {
        isLoading = true
        Task {
            let list = await PackageReceiptsEngine.shared.listThirdPartyReceipts()
            await MainActor.run { receipts = list; isLoading = false }
        }
    }

    private func forgetSelectedReceipt(_ pkg: PackageReceiptItem) {
        let blockingApps = PackageReceiptsEngine.shared.activeAppsBlockingForget(bomEntries: bomEntries)
        if !blockingApps.isEmpty {
            host.showBanner(ZtatL10n.tr(
                "收据关联的应用（\(blockingApps[0].lastPathComponent)）仍在「应用程序」中，请先在「应用卸载」中卸载。",
                "App \(blockingApps[0].lastPathComponent) is still installed; uninstall it from App Uninstaller first."
            ), isError: true)
            return
        }
        Task {
            let (ok, err) = await PackageReceiptsEngine.shared.forgetReceipt(pkg)
            await MainActor.run {
                host.showBanner(ok ? ZtatL10n.tr("已移除收据 \(pkg.packageID)。", "Forgot receipt \(pkg.packageID).") : (err ?? "Failed"), isError: !ok)
                if ok {
                    receipts.removeAll { $0.id == pkg.id }
                    selectedReceipt = nil
                    bomEntries = []
                }
            }
        }
    }

    private func uninstallPackage(_ pkg: PackageReceiptItem, entries: [PackageBOMEntry]) {
        Task {
            var urls = entries.map(\.url)
            if let p = pkg.receiptPlistURL { urls.append(p) }
            if let b = pkg.receiptBomURL { urls.append(b) }
            let res = await SafeDeletionEngine.shared.trashItems(
                urls: urls,
                bundleLabel: "PKG_\(pkg.displayName)",
                sourceModule: "packages"
            )
            await MainActor.run {
                host.showBanner(ZtatL10n.tr(
                    "已移除安装包 \(pkg.displayName) 的 \(res.succeededCount) 项文件，释放 \(CleanerFormatters.bytes(res.freedBytes))。",
                    "Removed \(res.succeededCount) items from \(pkg.displayName) (\(CleanerFormatters.bytes(res.freedBytes)))."
                ), isError: !res.failedItems.isEmpty)
                loadReceipts()
                selectedReceipt = nil
                bomEntries = []
            }
        }
    }
}

// MARK: - 5. 18-Category Plugins Manager View

struct CleanerPluginsView: View {
    @ObservedObject var host: ZtatCleanerHost
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    @State private var plugins: [PluginItem] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var relatedFiles: [String: [URL]] = [:]
    /// Related-file paths the user explicitly ticked; hits start unchecked.
    @State private var selectedRelatedPaths: Set<String> = []

    private var filtered: [PluginItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return plugins }
        return plugins.filter { $0.name.lowercased().contains(q) || $0.category.title.lowercased().contains(q) }
    }

    private var selectedPlugins: [PluginItem] {
        plugins.filter(\.isSelected)
    }

    private var selectedRelatedURLs: [URL] {
        var seen = Set<String>()
        return relatedFiles.values.flatMap { $0 }.filter {
            selectedRelatedPaths.contains($0.path) && seen.insert($0.path).inserted
        }
    }

    var body: some View {
        let _ = l10n.revision
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ZtatL10n.tr("系统插件与扩展管理（18 大分类）", "Plugins & Extensions Manager (18 Categories)"))
                        .font(.headline)
                    Text(ZtatL10n.tr("统一管理 AU/VST/VST3 音频插件、QuickLook、偏好面板、屏保、字体、Spotlight、输入法与小组件。", "Manage Audio AU/VST/VST3, QuickLook, PrefPanes, Screen Savers, Fonts, Spotlight, Input Methods, and Widgets."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField(ZtatL10n.tr("搜索插件…", "Search plugins…"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 180)
                Button { loadPlugins() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(14)

            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView(ZtatL10n.tr("未发现第三方系统插件", "No Third-Party Plugins Found"), systemImage: "puzzlepiece.extension")
            } else {
                let grouped = Dictionary(grouping: filtered, by: \.category)
                List {
                    ForEach(PluginCategory.allCases.filter { grouped[$0] != nil }) { cat in
                        Section {
                            ForEach(grouped[cat] ?? []) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Toggle("", isOn: Binding(
                                            get: { item.isSelected },
                                            set: { val in
                                                if let idx = plugins.firstIndex(where: { $0.id == item.id }) {
                                                    plugins[idx].isSelected = val
                                                }
                                            }
                                        ))
                                        .labelsHidden().toggleStyle(.checkbox)

                                        VStack(alignment: .leading, spacing: 1) {
                                            HStack(spacing: 5) {
                                                Text(item.name).font(.system(size: 12.5, weight: .medium))
                                                if item.isSystemDomain {
                                                    CleanerMicroBadge(text: ZtatL10n.tr("系统级", "System"), color: .orange)
                                                }
                                            }
                                            Text(item.displayPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if item.category == .audio {
                                            Button(ZtatL10n.tr("查关联文件", "Find Related")) {
                                                Task {
                                                    let found = await PluginsScannerEngine.shared.findRelatedFiles(for: item)
                                                    await MainActor.run { relatedFiles[item.id] = found }
                                                }
                                            }
                                            .controlSize(.mini)
                                        }
                                        Text(CleanerFormatters.bytes(item.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }

                                    if let extras = relatedFiles[item.id] {
                                        if extras.isEmpty {
                                            Text(ZtatL10n.tr("未找到关联文件", "No related files found"))
                                                .font(.caption2).foregroundStyle(.secondary).padding(.leading, 28)
                                        } else {
                                            ForEach(extras, id: \.path) { u in
                                                Toggle(isOn: Binding(
                                                    get: { selectedRelatedPaths.contains(u.path) },
                                                    set: { on in
                                                        if on { selectedRelatedPaths.insert(u.path) } else { selectedRelatedPaths.remove(u.path) }
                                                    }
                                                )) {
                                                    Text(u.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                                        .font(.caption2).foregroundStyle(.secondary)
                                                        .lineLimit(1).truncationMode(.middle)
                                                }
                                                .toggleStyle(.checkbox)
                                                .padding(.leading, 28)
                                            }
                                        }
                                    }
                                }
                                .contextMenu {
                                    Button(ZtatL10n.tr("在访达中显示", "Reveal in Finder")) {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                    }
                                }
                            }
                        } header: {
                            Label("\(cat.title) (\((grouped[cat] ?? []).count))", systemImage: cat.symbolName)
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
                .listStyle(.inset)

                Divider()
                HStack {
                    let relatedURLs = selectedRelatedURLs
                    let totalBytes = selectedPlugins.reduce(Int64(0)) { $0 + $1.size }
                    Text(ZtatL10n.tr(
                        "已选 \(selectedPlugins.count) 个插件 · \(relatedURLs.count) 个关联文件 · \(CleanerFormatters.bytes(totalBytes))",
                        "Selected \(selectedPlugins.count) plugins · \(relatedURLs.count) related files · \(CleanerFormatters.bytes(totalBytes))"
                    ))
                        .font(.callout.monospacedDigit())
                    Spacer()
                    Button(ZtatL10n.tr("移入废纸篓", "Move to Trash"), role: .destructive) {
                        var seen = Set<String>()
                        let urls = (selectedPlugins.map(\.url) + relatedURLs).filter { seen.insert($0.path).inserted }
                        let label = "Plugins_\(selectedPlugins.count)"
                        Task {
                            let res = await SafeDeletionEngine.shared.trashItems(urls: urls, bundleLabel: label, sourceModule: "plugins")
                            await MainActor.run {
                                host.showBanner(ZtatL10n.tr("已移除 \(res.succeededCount) 个插件文件，释放 \(CleanerFormatters.bytes(res.freedBytes))。", "Moved \(res.succeededCount) plugin items (\(CleanerFormatters.bytes(res.freedBytes))) to Trash."), isError: !res.failedItems.isEmpty)
                            }
                            loadPlugins()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selectedPlugins.isEmpty && relatedURLs.isEmpty)
                }
                .padding(14)
            }
        }
        .onAppear { if plugins.isEmpty { loadPlugins() } }
    }

    private func loadPlugins() {
        isLoading = true
        relatedFiles = [:]
        selectedRelatedPaths = []
        Task {
            let list = await PluginsScannerEngine.shared.scanPlugins()
            await MainActor.run { plugins = list; isLoading = false }
        }
    }
}

// MARK: - 6. Launch Services / Daemons Manager View

struct CleanerServicesView: View {
    @ObservedObject var host: ZtatCleanerHost
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    private enum FilterMode: String, CaseIterable, Identifiable {
        case all, running, loaded, agents, daemons, xpc
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return ZtatL10n.tr("全部", "All")
            case .running: return ZtatL10n.tr("运行中", "Running")
            case .loaded: return ZtatL10n.tr("已加载", "Loaded")
            case .agents: return "Agents"
            case .daemons: return "Daemons"
            case .xpc: return "XPC"
            }
        }
    }

    @State private var services: [LaunchServiceItem] = []
    @State private var filterMode: FilterMode = .all
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var pendingPlistTrash: PendingPlistTrash?

    /// A plist removal awaiting confirmation because stopping its job failed.
    private struct PendingPlistTrash {
        let service: LaunchServiceItem
        let plist: URL
        let stopError: String
    }

    private var filtered: [LaunchServiceItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return services.filter { svc in
            if !q.isEmpty && !svc.label.lowercased().contains(q) && !(svc.programPath?.lowercased().contains(q) ?? false) {
                return false
            }
            switch filterMode {
            case .all: return true
            case .running: return svc.isRunning
            case .loaded: return svc.isLoaded
            case .agents: return svc.kind == .userAgent || svc.kind == .globalAgent
            case .daemons: return svc.kind == .globalDaemon
            case .xpc: return svc.kind == .xpcService
            }
        }
    }

    var body: some View {
        let _ = l10n.revision
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $filterMode) {
                    ForEach(FilterMode.allCases) { m in Text(m.title).tag(m) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Spacer()
                TextField(ZtatL10n.tr("搜索服务标签…", "Search label…"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 180)
                Button { loadServices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(14)
            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView(ZtatL10n.tr("无匹配的第三方后台服务", "No Matching Launch Services"), systemImage: "gearshape.2")
            } else {
                List(filtered) { svc in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(svc.isRunning ? Color.green : (svc.isLoaded ? Color.orange : Color.secondary.opacity(0.4)))
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(svc.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                CleanerMicroBadge(text: svc.kind.title, color: (svc.requiresElevation || svc.plistRemovalRequiresAdmin) ? .orange : .blue)
                                if let pid = svc.pid, pid > 0 {
                                    CleanerMicroBadge(text: "PID \(pid)", color: .green)
                                }
                            }
                            if let path = svc.plistURL?.path ?? svc.programPath {
                                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }

                        Spacer()

                        HStack(spacing: 4) {
                            if svc.isLoaded {
                                Button(ZtatL10n.tr("停止", "Stop")) { runServiceAction(.stop, on: svc) }
                                    .controlSize(.mini)
                                Button(ZtatL10n.tr("重启", "Restart")) { runServiceAction(.restart, on: svc) }
                                    .controlSize(.mini)
                            } else {
                                Button(ZtatL10n.tr("启动", "Start")) { runServiceAction(.start, on: svc) }
                                    .controlSize(.mini)
                            }
                            if let target = svc.plistURL ?? svc.associatedAppURL {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([target])
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)
                                .help(ZtatL10n.tr("在访达中显示", "Reveal in Finder"))
                            }
                        }
                    }
                    .contextMenu {
                        Button(ZtatL10n.tr("从 launchd 移除任务", "Remove from launchd"), role: .destructive) {
                            runServiceAction(.remove, on: svc)
                        }
                        if let plist = svc.plistURL, svc.kind != .embeddedHelper && svc.kind != .xpcService {
                            Button(ZtatL10n.tr("将 plist 移入废纸篓", "Move plist to Trash"), role: .destructive) {
                                stopThenTrashPlist(svc, plist: plist)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { if services.isEmpty { loadServices() } }
        .alert(
            ZtatL10n.tr("无法停止服务", "Couldn't Stop Service"),
            isPresented: Binding(get: { pendingPlistTrash != nil }, set: { if !$0 { pendingPlistTrash = nil } }),
            presenting: pendingPlistTrash
        ) { pending in
            Button(ZtatL10n.tr("仍然移入废纸篓", "Move to Trash Anyway"), role: .destructive) {
                Task { await trashServicePlist(pending.service, plist: pending.plist) }
            }
            Button(ZtatL10n.tr("取消", "Cancel"), role: .cancel) {}
        } message: { pending in
            Text(ZtatL10n.tr(
                "\(pending.service.label) 仍由 launchd 加载：\(pending.stopError)\n移除 plist 后，该任务会继续运行到下次注销或重启。",
                "\(pending.service.label) is still loaded in launchd: \(pending.stopError)\nIf you remove the plist, the job keeps running until the next logout or restart."
            ))
        }
    }

    /// Stops the job first; the plist is only trashed after a failed stop if the user confirms.
    private func stopThenTrashPlist(_ svc: LaunchServiceItem, plist: URL) {
        Task {
            let (stopped, message) = await LaunchServicesEngine.shared.perform(.stop, on: svc)
            if stopped {
                await trashServicePlist(svc, plist: plist)
            } else {
                await MainActor.run {
                    pendingPlistTrash = PendingPlistTrash(service: svc, plist: plist, stopError: message)
                }
            }
        }
    }

    private func trashServicePlist(_ svc: LaunchServiceItem, plist: URL) async {
        let res = await SafeDeletionEngine.shared.trashItems(urls: [plist], bundleLabel: "Service_\(svc.label)", sourceModule: "services")
        await MainActor.run {
            if let failure = res.failedItems.first {
                host.showBanner(failure.reason, isError: true)
            } else {
                host.showBanner(ZtatL10n.tr("已将 \(plist.lastPathComponent) 移入废纸篓。", "Moved \(plist.lastPathComponent) to Trash."), isError: false)
            }
        }
        loadServices()
    }

    private func loadServices() {
        isLoading = true
        Task {
            let list = await LaunchServicesEngine.shared.scanServices()
            await MainActor.run { services = list; isLoading = false }
        }
    }

    private func runServiceAction(_ action: LaunchServicesEngine.ServiceAction, on svc: LaunchServiceItem) {
        Task {
            let (ok, msg) = await LaunchServicesEngine.shared.perform(action, on: svc)
            await MainActor.run {
                host.showBanner(ok ? "\(action.rawValue.capitalized): \(svc.label)" : msg, isError: !ok)
            }
            loadServices()
        }
    }
}

// MARK: - 7. Multi-Volume Deep File Search View

struct CleanerFileSearchView: View {
    @ObservedObject var host: ZtatCleanerHost
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    @State private var rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var nameText = ""
    @State private var nameMode: FileNameMatchMode = .contains
    @State private var extensionsCSV = ""
    @State private var minSizeMB = ""
    @State private var maxSizeMB = ""
    @State private var tagFilter = ""
    @State private var commentFilter = ""
    @State private var kindFilter: FileSearchKindFilter = .any
    @State private var includeHidden = false
    @State private var excludeSystem = true

    @State private var results: [FileSearchResultItem] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var renamingItem: FileSearchResultItem? = nil
    @State private var renameDraft = ""

    private var selectedResults: [FileSearchResultItem] {
        results.filter(\.isSelected)
    }

    var body: some View {
        let _ = l10n.revision
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(ZtatL10n.tr("搜索范围：", "Scope:"))
                        .font(.caption.weight(.semibold))
                    Text(rootURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(ZtatL10n.tr("选择文件夹…", "Choose Folder…")) { pickScopeFolder() }
                        .controlSize(.small)
                    Spacer()
                    Toggle(ZtatL10n.tr("隐藏文件", "Hidden"), isOn: $includeHidden).controlSize(.small)
                    Toggle(ZtatL10n.tr("跳过系统目录", "Exclude System"), isOn: $excludeSystem).controlSize(.small)
                }

                HStack(spacing: 8) {
                    Picker("", selection: $nameMode) {
                        ForEach(FileNameMatchMode.allCases) { m in Text(m.title).tag(m) }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 110)

                    TextField(ZtatL10n.tr("文件名 / 正则表达式…", "File name or regex…"), text: $nameText)
                        .textFieldStyle(.roundedBorder).controlSize(.small)

                    TextField(ZtatL10n.tr("扩展名 (如 dmg,pkg)", "Exts (e.g. dmg,pkg)"), text: $extensionsCSV)
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 150)

                    Picker("", selection: $kindFilter) {
                        ForEach(FileSearchKindFilter.allCases) { k in Text(k.title).tag(k) }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 120)
                }

                HStack(spacing: 8) {
                    TextField(ZtatL10n.tr("最小 MB", "Min MB"), text: $minSizeMB)
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 82)
                    TextField(ZtatL10n.tr("最大 MB", "Max MB"), text: $maxSizeMB)
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 82)
                    TextField(ZtatL10n.tr("访达标签", "Finder Tag"), text: $tagFilter)
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 120)
                    TextField(ZtatL10n.tr("访达注释", "Finder Comment"), text: $commentFilter)
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 140)
                    Spacer()
                    if isSearching {
                        Button(ZtatL10n.tr("停止搜索", "Stop")) {
                            searchTask?.cancel()
                            isSearching = false
                        }
                        .controlSize(.small)
                    } else {
                        Button {
                            runSearch()
                        } label: {
                            Label(ZtatL10n.tr("开始搜索", "Search"), systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .padding(14)

            Divider()

            if isSearching && results.isEmpty {
                ProgressView(ZtatL10n.tr("正在搜索文件…", "Searching files…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView(
                    ZtatL10n.tr("设置条件后点击“开始搜索”", "Set Filters and Click Search"),
                    systemImage: "magnifyingglass.circle",
                    description: Text(ZtatL10n.tr("支持正则、扩展名、体积、访达标签与注释筛选，并支持内联重命名与可逆删除。", "Supports regex, extension, size, Finder tags & comments, inline rename, and reversible trashing."))
                )
            } else {
                List {
                    ForEach($results) { $item in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $item.isSelected).labelsHidden().toggleStyle(.checkbox)
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                .resizable().frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(item.displayPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(CleanerFormatters.bytes(item.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button(ZtatL10n.tr("在访达中显示", "Reveal in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            }
                            Button(ZtatL10n.tr("重命名…", "Rename…")) {
                                renameDraft = item.name
                                renamingItem = item
                            }
                            Button(ZtatL10n.tr("打开", "Open")) {
                                NSWorkspace.shared.open(item.url)
                            }
                        }
                    }
                }
                .listStyle(.inset)

                Divider()
                HStack {
                    Text(ZtatL10n.tr("匹配 \(results.count) 项 · 已选 \(selectedResults.count) 项", "\(results.count) results · \(selectedResults.count) selected"))
                        .font(.caption)
                    Spacer()
                    Button(ZtatL10n.tr("移入废纸篓", "Move Selected to Trash"), role: .destructive) {
                        let targets = selectedResults
                        Task {
                            let res = await SafeDeletionEngine.shared.trashItems(
                                urls: targets.map(\.url),
                                bundleLabel: "FileSearch_\(targets.count)",
                                sourceModule: "fileSearch"
                            )
                            await MainActor.run {
                                let ids = Set(targets.map(\.id))
                                results.removeAll { ids.contains($0.id) }
                                host.showBanner(ZtatL10n.tr("已移入废纸篓 \(res.succeededCount) 项（\(CleanerFormatters.bytes(res.freedBytes))）。", "Trashed \(res.succeededCount) items (\(CleanerFormatters.bytes(res.freedBytes)))."), isError: !res.failedItems.isEmpty)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selectedResults.isEmpty)
                }
                .padding(14)
            }
        }
        .alert(ZtatL10n.tr("重命名文件", "Rename File"), isPresented: Binding(get: { renamingItem != nil }, set: { if !$0 { renamingItem = nil } })) {
            TextField("", text: $renameDraft)
            Button(ZtatL10n.tr("取消", "Cancel"), role: .cancel) { renamingItem = nil }
            Button(ZtatL10n.tr("确认", "Rename")) {
                if let item = renamingItem {
                    do {
                        let newURL = try FileSearchEngine.shared.renameItem(at: item.url, newName: renameDraft)
                        if let idx = results.firstIndex(where: { $0.id == item.id }) {
                            results[idx] = FileSearchResultItem(
                                id: newURL.path, url: newURL, name: newURL.lastPathComponent,
                                isDirectory: item.isDirectory, isPackage: item.isPackage,
                                size: item.size, modifiedDate: item.modifiedDate,
                                finderTags: item.finderTags, finderComment: item.finderComment,
                                isSelected: item.isSelected
                            )
                        }
                    } catch {
                        host.showBanner(error.localizedDescription, isError: true)
                    }
                }
                renamingItem = nil
            }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private func pickScopeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let u = panel.url {
            rootURL = u
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        isSearching = true
        results = []

        var q = FileSearchQuery(rootURL: rootURL)
        q.nameText = nameText
        q.nameMatchMode = nameMode
        q.extensionsCSV = extensionsCSV
        q.kindFilter = kindFilter
        q.includeHidden = includeHidden
        q.excludeSystemFolders = excludeSystem
        q.finderTagFilter = tagFilter
        q.finderCommentFilter = commentFilter
        if let minVal = Double(minSizeMB), minVal > 0 { q.minSizeBytes = Int64(minVal * 1_048_576) }
        if let maxVal = Double(maxSizeMB), maxVal > 0 { q.maxSizeBytes = Int64(maxVal * 1_048_576) }

        searchTask = Task {
            let found = await FileSearchEngine.shared.search(query: q)
            await MainActor.run {
                results = found
                isSearching = false
            }
        }
    }
}

// MARK: - 8. Delete History & Selective Restore View

struct CleanerDeleteHistoryView: View {
    @ObservedObject var host: ZtatCleanerHost
    @ObservedObject private var history = DeleteHistoryStore.shared
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    @State private var selectedIDs: Set<UUID> = []
    @State private var isRestoring = false

    var body: some View {
        let _ = l10n.revision
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ZtatL10n.tr("清理历史与废纸篓一键还原", "Delete History & Trash Restore"))
                        .font(.headline)
                    Text(ZtatL10n.tr("自动保留最近 10 次打包删除记录；在废纸篓未清空前可精准还原回原始路径。", "Retains the last 10 bundled Trash operations and restores items back to their original paths."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(ZtatL10n.tr("刷新状态", "Refresh")) { history.pruneStaleEntries() }
                    .controlSize(.small)
                Button(ZtatL10n.tr("清空记录", "Clear Log")) { history.clearAll() }
                    .controlSize(.small)
                    .disabled(history.entries.isEmpty)
            }
            .padding(14)

            Divider()

            if history.entries.isEmpty {
                ContentUnavailableView(
                    ZtatL10n.tr("暂无可还原的清理记录", "No Delete History Yet"),
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                List(history.entries) { entry in
                    let exists = entry.bundleStillExistsInTrash
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { selectedIDs.contains(entry.id) },
                            set: { on in if on { selectedIDs.insert(entry.id) } else { selectedIDs.remove(entry.id) } }
                        ))
                        .labelsHidden().toggleStyle(.checkbox)
                        .disabled(!exists)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(entry.operationTitle).font(.system(size: 13, weight: .semibold))
                                CleanerMicroBadge(text: entry.sourceModule, color: .blue)
                                if !exists {
                                    CleanerMicroBadge(text: ZtatL10n.tr("废纸篓已清空", "Emptied"), color: .red)
                                }
                            }
                            Text("\(entry.timestamp.formatted(date: .abbreviated, time: .shortened)) · \(entry.files.count) 项 · \(CleanerFormatters.bytes(entry.totalBytes))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(ZtatL10n.tr("还原", "Restore")) {
                            restoreEntries([entry])
                        }
                        .controlSize(.small)
                        .disabled(!exists || isRestoring)
                    }
                }
                .listStyle(.inset)

                Divider()
                HStack {
                    Text(ZtatL10n.tr("已选 \(selectedIDs.count) 条记录", "\(selectedIDs.count) selected"))
                        .font(.caption)
                    Spacer()
                    Button(ZtatL10n.tr("还原选中记录", "Restore Selected")) {
                        let chosen = history.entries.filter { selectedIDs.contains($0.id) }
                        restoreEntries(chosen)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIDs.isEmpty || isRestoring)
                }
                .padding(14)
            }
        }
        .onAppear { history.pruneStaleEntries() }
    }

    private func restoreEntries(_ targets: [DeleteHistoryEntry]) {
        isRestoring = true
        Task {
            var restoredTotal = 0
            var failedTotal = 0
            for entry in targets {
                let res = await SafeDeletionEngine.shared.restoreEntry(entry)
                restoredTotal += res.restoredCount
                failedTotal += res.failed.count
            }
            await MainActor.run {
                isRestoring = false
                selectedIDs.removeAll()
                host.showBanner(ZtatL10n.tr(
                    "已还原 \(restoredTotal) 个文件\(failedTotal > 0 ? "（\(failedTotal) 项失败）" : "")。",
                    "Restored \(restoredTotal) files\(failedTotal > 0 ? " (\(failedTotal) failed)" : "")."
                ), isError: failedTotal > 0)
            }
            await host.refreshInstalledApps()
        }
    }
}

// MARK: - 9. Cleaner Settings, Folders, Exclusions & Trash Sentinel View

struct CleanerSettingsView: View {
    @ObservedObject var host: ZtatCleanerHost
    @ObservedObject private var settings = CleanerSettingsStore.shared
    @ObservedObject private var sentinel = TrashSentinelMonitor.shared
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    @State private var newAppExclusion = ""
    @State private var newOrphanExclusion = ""
    @State private var newKeepLanguage = ""

    var body: some View {
        let _ = l10n.revision
        Form {
            Section(ZtatL10n.tr("废纸篓哨兵（自动残留清理提醒）", "Trash Sentinel Monitor")) {
                Toggle(isOn: $settings.sentinelEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ZtatL10n.tr("启用废纸篓哨兵监听", "Enable Trash Sentinel Monitor"))
                        Text(ZtatL10n.tr(
                            "将 .app 拖入废纸篓时自动唤起 ztat 扫描该应用的残留文件。关闭时彻底释放 FSEvents，零后台开销。",
                            "Automatically opens ztat App Uninstaller when an .app is dragged to Trash. Zero idle overhead when OFF."
                        ))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent(ZtatL10n.tr("当前监听状态", "Monitor State")) {
                    Text(sentinel.isRunning ? ZtatL10n.tr("运行中（进程内 FSEvents）", "Active (In-Process FSEvents)") : ZtatL10n.tr("已停止", "Stopped"))
                        .foregroundStyle(sentinel.isRunning ? .green : .secondary)
                }
                LabeledContent(ZtatL10n.tr("完全磁盘访问权限", "Full Disk Access")) {
                    HStack(spacing: 8) {
                        let fda = TCCPermissionsEngine.shared.hasFullDiskAccess()
                        Text(fda ? ZtatL10n.tr("已授权", "Granted") : ZtatL10n.tr("未授权（建议开启以读取容器与系统 TCC）", "Not Granted"))
                            .foregroundStyle(fda ? .green : .orange)
                        if !fda {
                            Button(ZtatL10n.tr("前往系统设置", "Open Settings")) {
                                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                    NSWorkspace.shared.open(u)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section(ZtatL10n.tr("扫描灵敏度与清理策略", "Scanning & Removal Behavior")) {
                Picker(ZtatL10n.tr("默认残留扫描灵敏度", "Default Scan Sensitivity"), selection: $settings.sensitivity) {
                    ForEach(CleanerSearchSensitivity.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                Text(settings.sensitivity.subtitle).font(.caption).foregroundStyle(.secondary)

                Toggle(ZtatL10n.tr("删除前弹出确认提示", "Confirm Before Moving to Trash"), isOn: $settings.confirmBeforeDelete)
                Toggle(ZtatL10n.tr("卸载 Homebrew Cask 应用时同步执行 brew --zap", "Run Homebrew --zap for Cask Apps"), isOn: $settings.homebrewZapEnabled)
            }

            Section(ZtatL10n.tr("应用程序扫描目录", "Application Scan Folders")) {
                Toggle(ZtatL10n.tr("锁定默认扫描路径（/Applications 与 ~/Applications）", "Lock Default App Folders"), isOn: $settings.lockDefaultAppPaths)
                ForEach(settings.appScanFolders, id: \.self) { folder in
                    HStack {
                        Text(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.callout.monospaced())
                        Spacer()
                        let locked = settings.lockDefaultAppPaths && CleanerSettingsStore.defaultAppScanFolders.contains(folder)
                        if !locked {
                            Button(role: .destructive) {
                                settings.removeAppScanFolder(folder)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button(ZtatL10n.tr("添加扫描目录…", "Add Scan Folder…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let u = panel.url {
                        settings.addAppScanFolder(u.path)
                    }
                }
            }

            Section(ZtatL10n.tr("语言包裁剪默认保留语言", "Preferred Languages to Keep")) {
                HStack {
                    TextField(ZtatL10n.tr("输入语言代码（如 zh-Hans / en / ja）", "Language code (e.g. zh-Hans, en, ja)"), text: $newKeepLanguage)
                    Button(ZtatL10n.tr("添加", "Add")) {
                        let code = newKeepLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !code.isEmpty && !settings.keepLanguageCodes.contains(code) {
                            settings.keepLanguageCodes.append(code)
                            newKeepLanguage = ""
                        }
                    }
                }
                ForEach(settings.keepLanguageCodes, id: \.self) { code in
                    HStack {
                        Text(code)
                        Spacer()
                        if code != "en" {
                            Button(role: .destructive) {
                                settings.keepLanguageCodes.removeAll { $0 == code }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section(ZtatL10n.tr("应用残留排除项（路径或关键词）", "App Leftover Exclusions")) {
                HStack {
                    TextField(ZtatL10n.tr("输入路径或关键词…", "Path or keyword…"), text: $newAppExclusion)
                    Button(ZtatL10n.tr("添加", "Add")) {
                        settings.addAppExclusion(newAppExclusion)
                        newAppExclusion = ""
                    }
                }
                ForEach(settings.appExclusions, id: \.self) { ex in
                    HStack {
                        Text(ex).font(.caption.monospaced())
                        Spacer()
                        Button(role: .destructive) { settings.removeAppExclusion(ex) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Section(ZtatL10n.tr("孤立残留排除项", "Orphan Scan Exclusions")) {
                HStack {
                    TextField(ZtatL10n.tr("输入路径或关键词…", "Path or keyword…"), text: $newOrphanExclusion)
                    Button(ZtatL10n.tr("添加", "Add")) {
                        settings.addOrphanExclusion(newOrphanExclusion)
                        newOrphanExclusion = ""
                    }
                }
                ForEach(settings.orphanExclusions, id: \.self) { ex in
                    HStack {
                        Text(ex).font(.caption.monospaced())
                        Spacer()
                        Button(role: .destructive) { settings.removeOrphanExclusion(ex) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Section {
                Button(ZtatL10n.tr("重置全部清理器偏好设置", "Reset All Cleaner Preferences"), role: .destructive) {
                    settings.resetAllPreferences()
                }
            }
        }
        .formStyle(.grouped)
    }
}
