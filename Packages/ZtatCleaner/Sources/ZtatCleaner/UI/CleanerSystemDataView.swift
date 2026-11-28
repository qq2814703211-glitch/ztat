// SPDX-License-Identifier: GPL-3.0-or-later
// Native SwiftUI view for ztat's System Data Unpacked module:
// Donut disk overview, proportional safety bars, Space Plan, project footprints,
// APFS transparent compression, history trend, and pre-action confirmation sheet.

import AppKit
import Charts
import SwiftUI
import ZtatCore

private enum SystemDataSubTab: String, CaseIterable, Identifiable {
    case categories
    case projects
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .categories: return ZtatL10n.tr("分类透视", "Categories")
        case .projects: return ZtatL10n.tr("项目占用", "Projects")
        case .history: return ZtatL10n.tr("趋势与回涨", "Trends")
        }
    }
}

private enum SystemDataSortMode: String, CaseIterable, Identifiable {
    case largest
    case oldestIdle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .largest: return ZtatL10n.tr("按体积", "Largest")
        case .oldestIdle: return ZtatL10n.tr("按最久未改", "Longest Idle")
        }
    }
}

struct CleanerSystemDataView: View {
    @ObservedObject var host: ZtatCleanerHost
    @ObservedObject var controller: SystemDataController
    @ObservedObject private var settings = CleanerSettingsStore.shared
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    @State private var activeTab: SystemDataSubTab = .categories
    @State private var sortMode: SystemDataSortMode = .largest
    @State private var searchText: String = ""
    @State private var expandedCategories: Set<SystemDataCategory> = []
    @State private var showConfirmSheet: Bool = false

    var body: some View {
        let _ = l10n.revision
        VStack(spacing: 0) {
            headerBar
            Divider()

            if !controller.hasFullDiskAccess {
                fdaBanner
                Divider()
            }

            if let banner = host.statusBanner {
                CleanerStatusBanner(message: banner, isError: host.statusBannerIsError) {
                    host.statusBanner = nil
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }

            if controller.isScanning {
                scanProgressStrip
                Divider()
            }

            if !controller.hasScannedOnce && !controller.isScanning {
                emptyStartState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        overviewCard
                        spacePlanStrip
                        tabControlBar

                        switch activeTab {
                        case .categories:
                            categoriesContent
                        case .projects:
                            projectsContent
                        case .history:
                            historyContent
                        }
                    }
                    .padding(14)
                }

                Divider()
                actionFooterBar
            }

            if settings.isConsoleOpen {
                Divider()
                CleanerConsoleDrawer(host: host)
                    .frame(height: 150)
            }
        }
        .sheet(isPresented: $showConfirmSheet) {
            reclaimConfirmationSheet
        }
        .onAppear {
            controller.refreshOverviewIfNeeded()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ZtatL10n.tr("系统数据透视", "System Data Inspector"))
                    .font(.title3.weight(.semibold))
                Text(ZtatL10n.tr(
                    "拆解 macOS「系统数据」真实占用：快照、模拟器、AI 模型、Docker、项目构建产物与大型缓存",
                    "Unpacks macOS System Data across snapshots, simulators, AI models, Docker, projects, and large caches"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Toggle(
                    ZtatL10n.tr("扫描外置磁盘中的项目产物", "Scan External Volumes for Projects"),
                    isOn: $settings.sysDataScanExternalVolumes
                )
                Toggle(
                    ZtatL10n.tr("清理前需要 Touch ID / 密码验证", "Require Touch ID / Password Before Reclaiming"),
                    isOn: $settings.sysDataRequireAuth
                )
                Toggle(
                    ZtatL10n.tr("记录本地扫描与回涨趋势", "Keep Local Scan History & Trends"),
                    isOn: $settings.sysDataHistoryEnabled
                )
                if !settings.sysDataHiddenIDs.isEmpty {
                    Divider()
                    Button(ZtatL10n.tr("恢复已隐藏项（\(settings.sysDataHiddenIDs.count)）", "Unhide \(settings.sysDataHiddenIDs.count) Hidden Items")) {
                        settings.sysDataHiddenIDs.removeAll()
                        controller.startScan(host: host)
                    }
                }
            } label: {
                Label(ZtatL10n.tr("选项", "Options"), systemImage: "slider.horizontal.3")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                settings.isConsoleOpen.toggle()
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(ZtatL10n.tr("开关清理日志抽屉", "Toggle Console Log"))

            if controller.isScanning {
                Button(ZtatL10n.tr("取消扫描", "Cancel")) {
                    controller.cancelScan()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    controller.startScan(host: host)
                } label: {
                    Label(
                        controller.hasScannedOnce
                            ? ZtatL10n.tr("重新透视", "Rescan")
                            : ZtatL10n.tr("开始透视扫描", "Start Scan"),
                        systemImage: "magnifyingglass"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var fdaBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            Text(ZtatL10n.tr(
                "尚未授予「完全磁盘访问权限」，部分系统日志、iOS 备份与受保护容器可能无法统计。",
                "Full Disk Access is not granted; some system logs, iOS backups, and protected containers may be skipped."
            ))
            .font(.caption)
            Spacer()
            Button(ZtatL10n.tr("前往权限设置", "Open Permissions")) {
                NotificationCenter.default.post(name: .ztatOpenSettings, object: ZtatSettingsRoute.permissions)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.10))
    }

    private var scanProgressStrip: some View {
        HStack(spacing: 10) {
            ProgressView(
                value: Double(controller.completedProbes),
                total: Double(max(1, controller.totalProbes))
            )
            .progressViewStyle(.linear)
            .frame(maxWidth: 220)

            Text("\(controller.completedProbes)/\(controller.totalProbes)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(controller.currentProbeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
    }

    private var emptyStartState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(ZtatL10n.tr("按需透视 macOS「系统数据」", "Inspect macOS System Data On Demand"))
                .font(.headline)
            Text(ZtatL10n.tr(
                "零后台常驻扫描。点击下方按钮后将并发分析本地快照、Xcode、模拟器、AI 模型、Docker、虚拟机、项目构建产物及大型目录；所有文件清理默认移入可还原废纸篓。",
                "Strict zero-idle. Scans APFS snapshots, Xcode, simulators, AI models, Docker, VMs, project artifacts, and large folders on demand. File removals move to reversible Trash bundles."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)

            Button {
                controller.startScan(host: host)
            } label: {
                Label(ZtatL10n.tr("开始系统数据透视", "Scan System Data"), systemImage: "sparkle.magnifyingglass")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Overview Card (Donut Chart + Volume Breakdown)

    private struct DonutSlice: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let color: Color
    }

    private var donutSlices: [DonutSlice] {
        let vol = controller.volumeOverview
        let safe = controller.totalSafeBytes
        let review = controller.totalReviewBytes
        let manual = controller.totalManualBytes
        let measured = safe + review + manual
        let otherUsed = max(0, vol.usedBytes - measured)
        let free = vol.availableBytes

        return [
            DonutSlice(id: "safe", label: ZtatL10n.tr("安全可清理", "Safe"), bytes: safe, color: .green),
            DonutSlice(id: "review", label: ZtatL10n.tr("建议确认", "Review"), bytes: review, color: .orange),
            DonutSlice(id: "manual", label: ZtatL10n.tr("系统/手动", "Manual"), bytes: manual, color: .gray),
            DonutSlice(id: "other", label: ZtatL10n.tr("其他已用", "Other Used"), bytes: otherUsed, color: .blue.opacity(0.45)),
            DonutSlice(id: "free", label: ZtatL10n.tr("可用空间", "Free"), bytes: free, color: Color.primary.opacity(0.08))
        ].filter { $0.bytes > 0 }
    }

    private var overviewCard: some View {
        HStack(spacing: 18) {
            ZStack {
                Chart(donutSlices) { slice in
                    SectorMark(
                        angle: .value("Bytes", slice.bytes),
                        innerRadius: .ratio(0.64),
                        angularInset: 1.2
                    )
                    .foregroundStyle(slice.color)
                    .cornerRadius(3)
                }
                .frame(width: 118, height: 118)

                VStack(spacing: 1) {
                    Text(CleanerFormatters.bytes(controller.totalSafeBytes))
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(.green)
                    Text(ZtatL10n.tr("安全可释放", "Safe to Free"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(ZtatL10n.tr("已识别系统数据", "Unpacked System Data"))
                        .font(.headline)
                    Text(CleanerFormatters.bytes(controller.totalMeasuredBytes))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.primary)

                    if let delta = controller.weekDeltaBytes, delta != 0 {
                        let sign = delta > 0 ? "+" : "-"
                        CleanerMicroBadge(
                            text: "\(sign)\(CleanerFormatters.bytes(abs(delta)))",
                            color: delta > 0 ? .orange : .green
                        )
                    }
                }

                HStack(spacing: 14) {
                    legendMetric(color: .green, title: ZtatL10n.tr("安全清理", "Safe"), bytes: controller.totalSafeBytes)
                    legendMetric(color: .orange, title: ZtatL10n.tr("建议确认", "Review"), bytes: controller.totalReviewBytes)
                    legendMetric(color: .gray, title: ZtatL10n.tr("仅查看/手动", "Manual"), bytes: controller.totalManualBytes)
                }

                HStack(spacing: 14) {
                    Text(ZtatL10n.tr(
                        "启动卷：可用 \(CleanerFormatters.bytes(controller.volumeOverview.availableBytes)) / 总计 \(CleanerFormatters.bytes(controller.volumeOverview.totalBytes))",
                        "Boot Volume: \(CleanerFormatters.bytes(controller.volumeOverview.availableBytes)) free / \(CleanerFormatters.bytes(controller.volumeOverview.totalBytes))"
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    if controller.volumeOverview.purgeableBytes > 100 * 1_048_576 {
                        CleanerMicroBadge(
                            text: ZtatL10n.tr(
                                "可清除 \(CleanerFormatters.bytes(controller.volumeOverview.purgeableBytes))",
                                "Purgeable \(CleanerFormatters.bytes(controller.volumeOverview.purgeableBytes))"
                            ),
                            color: .cyan
                        )
                    }
                }
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func legendMetric(color: Color, title: String, bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(CleanerFormatters.bytes(bytes)).font(.caption.weight(.semibold).monospacedDigit())
        }
    }

    // MARK: - Space Plan Strip

    private var spacePlanStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.tint)
                .font(.caption)
            Text(ZtatL10n.tr("目标腾空方案：", "Free Up Target:"))
                .font(.caption.weight(.medium))

            ForEach([5, 10, 20, 50], id: \.self) { gb in
                Button("\(gb) GB") {
                    controller.applySpacePlan(targetGigabytes: gb)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Button(ZtatL10n.tr("全选安全项", "Select All Safe")) {
                controller.selectAllSafe()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            if !controller.selectedItemIDs.isEmpty {
                Button(ZtatL10n.tr("清空勾选", "Clear")) {
                    controller.clearSelection()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let plan = controller.activeSpacePlan {
                Text(plan.reachedTarget
                     ? ZtatL10n.tr("已规划 \(CleanerFormatters.bytes(plan.plannedBytes))", "Planned \(CleanerFormatters.bytes(plan.plannedBytes))")
                     : ZtatL10n.tr("当前最多可规划 \(CleanerFormatters.bytes(plan.plannedBytes))", "Max plannable: \(CleanerFormatters.bytes(plan.plannedBytes))"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(plan.reachedTarget ? .green : .orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // MARK: - Sub-Tab & Filter Bar

    private var tabControlBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $activeTab) {
                ForEach(SystemDataSubTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            Spacer()

            if activeTab != .history {
                TextField(ZtatL10n.tr("搜索目录、项目或模型…", "Filter items, projects, models…"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
                    .controlSize(.small)

                Picker("", selection: $sortMode) {
                    ForEach(SystemDataSortMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 105)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Categories Tab

    private var filteredSummaries: [SystemDataCategorySummary] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return controller.categorySummaries.compactMap { summary in
            let matching = q.isEmpty ? summary.items : summary.items.filter {
                $0.title.lowercased().contains(q)
                    || $0.subtitle.lowercased().contains(q)
                    || summary.category.title.lowercased().contains(q)
            }
            guard !matching.isEmpty else { return nil }
            let sorted: [SystemDataItem]
            switch sortMode {
            case .largest:
                sorted = matching.sorted { $0.bytes > $1.bytes }
            case .oldestIdle:
                sorted = matching.sorted { ($0.lastModified ?? .distantFuture) < ($1.lastModified ?? .distantFuture) }
            }
            return SystemDataCategorySummary(
                category: summary.category,
                items: sorted,
                totalBytes: sorted.reduce(0) { $0 + $1.bytes },
                safeBytes: sorted.filter { $0.safety == .safe && $0.action.isActionable }.reduce(0) { $0 + $1.bytes },
                reviewBytes: sorted.filter { $0.safety == .review && $0.action.isActionable }.reduce(0) { $0 + $1.bytes },
                manualBytes: sorted.filter { $0.safety == .manual || !$0.action.isActionable }.reduce(0) { $0 + $1.bytes }
            )
        }
    }

    private var categoriesContent: some View {
        LazyVStack(spacing: 8) {
            if filteredSummaries.isEmpty {
                Text(ZtatL10n.tr("没有匹配的系统数据项。", "No matching System Data items."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 28)
            } else {
                let maxCatBytes = max(1, filteredSummaries.map(\.totalBytes).max() ?? 1)
                ForEach(filteredSummaries) { summary in
                    categorySectionCard(summary: summary, maxCategoryBytes: maxCatBytes)
                }
            }
        }
    }

    private func categorySectionCard(summary: SystemDataCategorySummary, maxCategoryBytes: Int64) -> some View {
        let isExpanded = expandedCategories.contains(summary.category) || !searchText.isEmpty
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if expandedCategories.contains(summary.category) {
                        expandedCategories.remove(summary.category)
                    } else {
                        expandedCategories.insert(summary.category)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Image(systemName: summary.category.symbolName)
                        .foregroundStyle(summary.category.tintColor)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(summary.category.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(summary.items.count)")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .foregroundStyle(.secondary)
                        }
                        ProportionalSafetyBar(
                            safeBytes: summary.safeBytes,
                            reviewBytes: summary.reviewBytes,
                            manualBytes: summary.manualBytes,
                            scaleMax: maxCategoryBytes
                        )
                        .frame(height: 5)
                    }

                    Spacer()

                    Text(CleanerFormatters.bytes(summary.totalBytes))
                        .font(.callout.weight(.semibold).monospacedDigit())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                VStack(spacing: 0) {
                    ForEach(summary.items) { item in
                        itemRow(item)
                        if item.id != summary.items.last?.id {
                            Divider().padding(.leading, 36)
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func itemRow(_ item: SystemDataItem) -> some View {
        let isSelected = controller.selectedItemIDs.contains(item.id)
        return HStack(spacing: 10) {
            if item.action.isActionable {
                Toggle("", isOn: Binding(
                    get: { isSelected },
                    set: { _ in controller.toggleSelection(for: item) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            } else {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    CleanerMicroBadge(text: item.safety.title, color: item.safety.color)
                    CleanerMicroBadge(text: item.recovery.title, color: .secondary)
                    if let days = item.idleDays, days >= 30 {
                        CleanerMicroBadge(
                            text: ZtatL10n.tr("闲置 \(days) 天", "\(days)d idle"),
                            color: .purple
                        )
                    }
                    if item.isStalled {
                        CleanerMicroBadge(text: ZtatL10n.tr("部分超时", "Partial"), color: .yellow)
                    }
                }

                Text(item.detailNote ?? item.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if item.isCompressible, item.path != nil {
                Button {
                    Task { await controller.compressItem(item, host: host) }
                } label: {
                    if controller.isCompressingID == item.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(ZtatL10n.tr("APFS压缩", "Compress"))
                            .font(.caption2)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(controller.isCompressingID != nil)
                .help(ZtatL10n.tr("使用 APFS 透明压缩减小占用，文件保持原地可读", "Compress transparently with APFS ditto; files stay readable in place"))
            }

            if let path = item.path {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([path])
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(ZtatL10n.tr("在访达中显示", "Reveal in Finder"))
            }

            Text(CleanerFormatters.bytes(item.bytes))
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(minWidth: 68, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contextMenu {
            if let path = item.path {
                Button(ZtatL10n.tr("在访达中显示", "Reveal in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([path])
                }
                Button(ZtatL10n.tr("复制路径", "Copy Path")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path.path, forType: .string)
                }
            }
            Button(ZtatL10n.tr("隐藏此项", "Hide Item")) {
                controller.hideItem(item)
            }
        }
    }

    // MARK: - Projects Tab

    private var filteredProjects: [ProjectFootprintGroup] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = q.isEmpty ? controller.projectGroups : controller.projectGroups.filter {
            $0.projectName.lowercased().contains(q) || $0.projectRoot.path.lowercased().contains(q)
        }
        switch sortMode {
        case .largest:
            return base.sorted { $0.totalBytes > $1.totalBytes }
        case .oldestIdle:
            return base.sorted { ($0.lastSourceModified ?? .distantPast) < ($1.lastSourceModified ?? .distantPast) }
        }
    }

    private var projectsContent: some View {
        LazyVStack(spacing: 8) {
            if filteredProjects.isEmpty {
                Text(ZtatL10n.tr("未发现大型项目构建产物（node_modules / .build / target / DerivedData 等）。",
                                "No large project build artifacts found (node_modules, .build, target, DerivedData, etc.)."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 28)
            } else {
                ForEach(filteredProjects) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.gearshape")
                                .foregroundStyle(.pink)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(group.projectName)
                                        .font(.system(size: 13, weight: .semibold))
                                    if !group.rootExists {
                                        CleanerMicroBadge(text: ZtatL10n.tr("原项目已删除", "Orphaned"), color: .orange)
                                    } else if let days = group.idleDays {
                                        CleanerMicroBadge(
                                            text: days <= 7
                                                ? ZtatL10n.tr("近期活跃", "Active")
                                                : ZtatL10n.tr("闲置 \(days) 天", "\(days)d idle"),
                                            color: days <= 7 ? .blue : .purple
                                        )
                                    }
                                }
                                Text(group.projectRoot.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(ZtatL10n.tr("勾选全部产物", "Select Artifacts")) {
                                controller.selectProjectArtifacts(group)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Text(CleanerFormatters.bytes(group.totalBytes))
                                .font(.callout.weight(.semibold).monospacedDigit())
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)

                        Divider()
                        ForEach(group.items) { item in
                            itemRow(item)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.025))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: - History & Returned Caches Tab

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(ZtatL10n.tr("系统数据历史趋势", "System Data Trend"))
                    .font(.headline)
                Spacer()
                if !controller.scanHistory.isEmpty {
                    Button(ZtatL10n.tr("清空历史记录", "Clear History")) {
                        controller.clearHistory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if controller.scanHistory.count < 2 {
                Text(ZtatL10n.tr("完成至少 2 次透视扫描后，此处将显示空间变化趋势曲线。",
                                "Complete at least 2 scans to display the System Data trend chart."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                Chart(controller.scanHistory) { record in
                    AreaMark(
                        x: .value("Date", record.timestamp),
                        y: .value("GB", Double(record.totalBytes) / 1_000_000_000.0)
                    )
                    .foregroundStyle(.blue.opacity(0.15))

                    LineMark(
                        x: .value("Date", record.timestamp),
                        y: .value("GB", Double(record.totalBytes) / 1_000_000_000.0)
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)
                }
                .chartYAxisLabel("GB")
                .frame(height: 160)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.025))
                )
            }

            if !controller.returnedItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ZtatL10n.tr("清理后重新增长的缓存", "Caches That Grew Back"))
                        .font(.headline)
                    ForEach(controller.returnedItems) { ret in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ret.title).font(.callout.weight(.medium))
                                Text(ZtatL10n.tr(
                                    "上次释放 \(CleanerFormatters.bytes(ret.previouslyFreedBytes))，现已回涨至 \(CleanerFormatters.bytes(ret.currentBytes))",
                                    "Previously freed \(CleanerFormatters.bytes(ret.previouslyFreedBytes)), now back to \(CleanerFormatters.bytes(ret.currentBytes))"
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            CleanerMicroBadge(text: CleanerFormatters.bytes(ret.currentBytes), color: .orange)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.orange.opacity(0.06))
                        )
                    }
                }
            }
        }
    }

    // MARK: - Footer & Confirmation Sheet

    private var actionFooterBar: some View {
        HStack(spacing: 10) {
            Text(ZtatL10n.tr(
                "已选 \(controller.selectedItems.count) 项 · 预计释放 \(CleanerFormatters.bytes(controller.selectedBytes))",
                "Selected \(controller.selectedItems.count) items · Est. \(CleanerFormatters.bytes(controller.selectedBytes))"
            ))
            .font(.callout.monospacedDigit())

            Spacer()

            Button {
                showConfirmSheet = true
            } label: {
                if controller.isReclaiming {
                    ProgressView().controlSize(.small)
                } else {
                    Label(ZtatL10n.tr("审查并清理所选项…", "Review & Reclaim…"), systemImage: "trash")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.selectedItems.isEmpty || controller.isReclaiming)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var reclaimConfirmationSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ZtatL10n.tr("确认清理所选系统数据", "Confirm System Data Reclaim"))
                        .font(.headline)
                    Text(ZtatL10n.tr(
                        "共 \(controller.selectedItems.count) 项，预计释放 \(CleanerFormatters.bytes(controller.selectedBytes))。普通文件将移入可还原废纸篓；CLI/快照命令将直接执行。",
                        "\(controller.selectedItems.count) items (~\(CleanerFormatters.bytes(controller.selectedBytes))). File paths move to reversible Trash; CLI/snapshot commands run directly."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            List(controller.selectedItems) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.title).font(.callout.weight(.medium))
                        Spacer()
                        CleanerMicroBadge(text: item.safety.title, color: item.safety.color)
                        Text(CleanerFormatters.bytes(item.bytes))
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    Text(item.action.previewCommand)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 200, maxHeight: 340)

            HStack {
                if settings.sysDataRequireAuth {
                    Label(ZtatL10n.tr("执行时将请求 Touch ID / 密码", "Touch ID / Password required"), systemImage: "touchid")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(ZtatL10n.tr("取消", "Cancel")) {
                    showConfirmSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button(ZtatL10n.tr("确认执行清理", "Reclaim Now")) {
                    showConfirmSheet = false
                    Task { await controller.reclaimSelected(host: host) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}

// MARK: - Proportional Safety Bar

private struct ProportionalSafetyBar: View {
    let safeBytes: Int64
    let reviewBytes: Int64
    let manualBytes: Int64
    let scaleMax: Int64

    var body: some View {
        GeometryReader { geo in
            let total = max(1, safeBytes + reviewBytes + manualBytes)
            let fillRatio = min(1.0, Double(total) / Double(max(1, scaleMax)))
            let barWidth = max(6, geo.size.width * fillRatio)
            let safeW = barWidth * (Double(safeBytes) / Double(total))
            let reviewW = barWidth * (Double(reviewBytes) / Double(total))
            let manualW = max(0, barWidth - safeW - reviewW)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                HStack(spacing: 0) {
                    if safeW > 0 { Rectangle().fill(Color.green).frame(width: safeW) }
                    if reviewW > 0 { Rectangle().fill(Color.orange).frame(width: reviewW) }
                    if manualW > 0 { Rectangle().fill(Color.gray.opacity(0.6)).frame(width: manualW) }
                }
                .clipShape(Capsule())
            }
        }
    }
}
