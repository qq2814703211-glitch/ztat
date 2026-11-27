// SPDX-License-Identifier: GPL-3.0-or-later
// Flagship App Uninstaller SwiftUI view:
// Disk Volume Dashboard, List/Grid app browser with System/User sections, 6 sort orders,
// multi-select queue, window-wide .app drag-and-drop, 13-category / flat leftover inspector,
// Full Uninstall & 1-Click Reset App, Single-App Lipo, Language Pruner sheet, TCC Viewer sheet,
// Export Paths, Ditto Archive Bundle, and Collapsible Console Drawer.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZtatCore

struct CleanerAppsUninstallerView: View {
    @ObservedObject var host: ZtatCleanerHost
    @ObservedObject private var settings = CleanerSettingsStore.shared
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    @State private var searchText = ""
    @State private var sortOrder: AppSortOrder = .name
    @State private var fileSortOrder: FileSortOrder = .size
    @State private var fileFilterText = ""
    @State private var multiSelectMode = false
    @State private var dropTargeted = false
    @State private var collapsedCategories: Set<LeftoverCategory> = []
    @State private var showConfirmDelete = false
    @State private var showTCCSheet = false
    @State private var showLanguagesSheet = false
    @State private var isThinningSingleApp = false

    private var filteredApps: [InstalledAppEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = query.isEmpty ? host.installedApps : host.installedApps.filter { app in
            app.name.lowercased().contains(query)
            || app.bundleIdentifier.lowercased().contains(query)
            || (app.homebrewCaskToken?.lowercased().contains(query) == true)
        }
        switch sortOrder {
        case .name:
            return base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return base.sorted { $0.bundleSize > $1.bundleSize }
        case .dateAdded:
            return base.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .dateModified:
            return base.sorted { ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast) }
        case .dateCreated:
            return base.sorted { ($0.dateCreated ?? .distantPast) > ($1.dateCreated ?? .distantPast) }
        case .lastUsed:
            return base.sorted { ($0.lastUsedDate ?? .distantPast) > ($1.lastUsedDate ?? .distantPast) }
        }
    }

    private var filteredLeftovers: [LeftoverItem] {
        let q = fileFilterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = q.isEmpty ? host.leftovers : host.leftovers.filter {
            $0.name.lowercased().contains(q) || $0.displayPath.lowercased().contains(q)
        }
        return base.sorted { lhs, rhs in
            if lhs.category == .appBundle && rhs.category != .appBundle { return true }
            if lhs.category != .appBundle && rhs.category == .appBundle { return false }
            switch fileSortOrder {
            case .size: return lhs.size > rhs.size
            case .name: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .path: return lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending
            }
        }
    }

    private var selectedLeftoverCount: Int {
        host.leftovers.filter(\.isSelected).count
    }

    private var selectedLeftoverBytes: Int64 {
        host.leftovers.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    private var isResetOnlyMode: Bool {
        guard let app = host.selectedApp, !app.isAlreadyInTrash else { return false }
        let hasAppChecked = host.leftovers.contains { $0.category == .appBundle && $0.isSelected }
        return !hasAppChecked && selectedLeftoverCount > 0
    }

    var body: some View {
        let _ = l10n.revision
        VStack(spacing: 0) {
            if let banner = host.statusBanner {
                CleanerStatusBanner(message: banner, isError: host.statusBannerIsError) {
                    host.statusBanner = nil
                }
            }

            HSplitView {
                appSidebarPane
                    .frame(minWidth: 235, idealWidth: 268, maxWidth: 420)

                detailInspectorPane
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }

            if settings.isConsoleOpen {
                Divider()
                CleanerConsoleDrawer(host: host)
                    .frame(height: 120)
            }
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    Color.accentColor.opacity(0.14)
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.app.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(Color.accentColor)
                        Text(ZtatL10n.tr("松开以深度分析并卸载此应用", "Drop .app Bundle to Inspect & Uninstall"))
                            .font(.headline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .onAppear {
            host.ensureAppsLoaded()
        }
        .alert(
            isResetOnlyMode
                ? ZtatL10n.tr("确认重置应用数据？", "Confirm Reset App Data?")
                : ZtatL10n.tr("确认移入废纸篓？", "Confirm Move to Trash?"),
            isPresented: $showConfirmDelete
        ) {
            Button(ZtatL10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(
                isResetOnlyMode ? ZtatL10n.tr("重置数据", "Reset Data") : ZtatL10n.tr("移入废纸篓", "Move to Trash"),
                role: .destructive
            ) {
                Task { await host.executeSelectedRemoval() }
            }
        } message: {
            Text(ZtatL10n.tr(
                "将把已选中的 \(selectedLeftoverCount) 项（共 \(CleanerFormatters.bytes(selectedLeftoverBytes))）打包移入废纸篓，随时可在「清理历史与还原」中恢复。",
                "Will move \(selectedLeftoverCount) selected items (\(CleanerFormatters.bytes(selectedLeftoverBytes))) into a single Trash bundle. You can restore them anytime in Delete History."
            ))
        }
        .sheet(isPresented: $showTCCSheet) {
            if let app = host.selectedApp {
                TCCPermissionsSheet(app: app)
            }
        }
        .sheet(isPresented: $showLanguagesSheet) {
            if let app = host.selectedApp {
                AppLanguagesPrunerSheet(app: app, host: host)
            }
        }
    }

    // MARK: - Left App Browser Pane

    private var appSidebarPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(ZtatL10n.tr("搜索应用名或 Bundle ID…", "Search apps or bundle ID…"), text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                HStack(spacing: 6) {
                    Picker("", selection: $sortOrder) {
                        ForEach(AppSortOrder.allCases) { opt in
                            Text(opt.title).tag(opt)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)

                    Spacer()

                    Button {
                        settings.preferGridAppList.toggle()
                    } label: {
                        Image(systemName: settings.preferGridAppList ? "list.bullet" : "square.grid.2x2")
                    }
                    .buttonStyle(.borderless)
                    .help(ZtatL10n.tr("切换列表 / 网格视图", "Toggle List / Grid View"))

                    Button {
                        multiSelectMode.toggle()
                        if !multiSelectMode { host.multiSelectedAppIDs.removeAll() }
                    } label: {
                        Image(systemName: multiSelectMode ? "checklist.checked" : "checklist")
                            .foregroundStyle(multiSelectMode ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(ZtatL10n.tr("批量多选队列", "Multi-Select Queue"))

                    Button {
                        Task { await host.refreshInstalledApps() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(host.isLoadingApps)
                    .help(ZtatL10n.tr("刷新应用列表", "Refresh Apps"))
                }
            }
            .padding(10)

            Divider()

            if host.isLoadingApps && host.installedApps.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(ZtatL10n.tr("正在扫描应用程序…", "Scanning applications…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredApps.isEmpty {
                ContentUnavailableView(
                    ZtatL10n.tr("未找到匹配应用", "No Matching Apps"),
                    systemImage: "app.dashed",
                    description: Text(ZtatL10n.tr("可直接将 .app 拖入此窗口进行卸载分析", "Drag and drop any .app bundle here to inspect"))
                )
            } else if settings.preferGridAppList {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 10) {
                        ForEach(filteredApps) { app in
                            appGridCell(app)
                        }
                    }
                    .padding(10)
                }
            } else {
                let userApps = filteredApps.filter { !$0.isSystemDomain }
                let sysApps = filteredApps.filter { $0.isSystemDomain }
                List {
                    if !userApps.isEmpty {
                        Section(ZtatL10n.tr("用户应用 (~/Applications · \(userApps.count))", "User Apps (\(userApps.count))")) {
                            ForEach(userApps) { app in appListRow(app) }
                        }
                    }
                    if !sysApps.isEmpty {
                        Section(ZtatL10n.tr("应用程序 (/Applications · \(sysApps.count))", "Applications (\(sysApps.count))")) {
                            ForEach(sysApps) { app in appListRow(app) }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            HStack {
                Text(ZtatL10n.tr("共 \(filteredApps.count) 个应用", "\(filteredApps.count) apps"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if multiSelectMode && !host.multiSelectedAppIDs.isEmpty {
                    Button(ZtatL10n.tr("按队列处理 (\(host.multiSelectedAppIDs.count))", "Queue (\(host.multiSelectedAppIDs.count))")) {
                        if let firstID = host.multiSelectedAppIDs.first,
                           let first = host.installedApps.first(where: { $0.id == firstID }) {
                            host.selectApp(first)
                        }
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    settings.isConsoleOpen.toggle()
                } label: {
                    Image(systemName: "terminal")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(ZtatL10n.tr("展开/收起控制台日志", "Toggle Console Log"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func appListRow(_ app: InstalledAppEntry) -> some View {
        let isSelected = host.selectedApp?.id == app.id
        return HStack(spacing: 8) {
            if multiSelectMode {
                Toggle("", isOn: Binding(
                    get: { host.multiSelectedAppIDs.contains(app.id) },
                    set: { on in
                        if on { host.multiSelectedAppIDs.insert(app.id) } else { host.multiSelectedAppIDs.remove(app.id) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }

            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                    if app.isWrappediOS {
                        CleanerMicroBadge(text: "iOS", color: .blue)
                    } else if app.isWebApp {
                        CleanerMicroBadge(text: "Web", color: .teal)
                    } else if app.isSteamGame {
                        CleanerMicroBadge(text: "Steam", color: .indigo)
                    }
                }
                HStack(spacing: 6) {
                    Text(CleanerFormatters.bytes(app.bundleSize))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if app.architecture == .universal {
                        CleanerMicroBadge(text: "UNI", color: .purple)
                    }
                    if app.homebrewCaskToken != nil {
                        CleanerMicroBadge(text: "Brew", color: .orange)
                    }
                }
            }
            Spacer(minLength: 2)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .onTapGesture {
            host.selectApp(app)
        }
        .contextMenu {
            Button(ZtatL10n.tr("在访达中显示", "Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            }
            Button(ZtatL10n.tr("拷贝路径", "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.url.path, forType: .string)
            }
        }
    }

    private func appGridCell(_ app: InstalledAppEntry) -> some View {
        let isSelected = host.selectedApp?.id == app.id
        return VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 40, height: 40)
            Text(app.name)
                .font(.caption2)
                .lineLimit(1)
            Text(CleanerFormatters.bytes(app.bundleSize))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .onTapGesture { host.selectApp(app) }
    }

    // MARK: - Right Inspector Pane (Landing Dashboard or Selected App)

    @ViewBuilder
    private var detailInspectorPane: some View {
        if let app = host.selectedApp {
            selectedAppDetailView(app)
        } else {
            landingDashboardView
        }
    }

    private var landingDashboardView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Hero Drop Zone
                VStack(spacing: 12) {
                    Image(systemName: "trash.square.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accentColor)
                    Text(ZtatL10n.tr("应用深度卸载与残留清理", "Deep App Uninstaller & Cleaner"))
                        .font(.title3.bold())
                    Text(ZtatL10n.tr(
                        "从左侧选择应用，或将任意 .app 拖入窗口；支持 13 类残留定位、一键重置应用数据、通用架构瘦身、语言包裁剪与废纸篓可逆还原。",
                        "Select an app on the left or drag any .app bundle here. Supports 13 leftover categories, 1-click App Reset, Universal Lipo thinning, translation pruning, and reversible Trash bundles."
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                    HStack(spacing: 10) {
                        Button {
                            pickAppBundleManually()
                        } label: {
                            Label(ZtatL10n.tr("选择 .app 文件…", "Choose .app Bundle…"), systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            NotificationCenter.default.post(name: .ztatOpenSettings, object: ZtatSettingsRoute.cleaner(sectionID: CleanerSectionID.orphans.rawValue))
                        } label: {
                            Label(ZtatL10n.tr("扫描孤立残留", "Scan Orphans"), systemImage: "doc.badge.ellipsis")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                )

                // Disk Volumes Dashboard
                if !host.diskVolumes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(ZtatL10n.tr("磁盘存储概览", "Storage Volumes"), systemImage: "internaldrive.fill")
                                .font(.headline)
                            Spacer()
                            Button(ZtatL10n.tr("系统存储设置", "Storage Settings")) {
                                if let u = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
                                    NSWorkspace.shared.open(u)
                                }
                            }
                            .controlSize(.small)
                            .buttonStyle(.link)
                        }

                        ForEach(host.diskVolumes) { vol in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: vol.isRootVolume ? "internaldrive" : "externaldrive")
                                        .foregroundStyle(vol.isRootVolume ? Color.accentColor : .orange)
                                    Text(vol.name)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(ZtatL10n.tr(
                                        "可用 \(CleanerFormatters.bytes(vol.availableBytes)) / 共 \(CleanerFormatters.bytes(vol.totalBytes))",
                                        "\(CleanerFormatters.bytes(vol.availableBytes)) free of \(CleanerFormatters.bytes(vol.totalBytes))"
                                    ))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)

                                    if vol.isRemovable {
                                        Button {
                                            try? NSWorkspace.shared.unmountAndEjectDevice(at: vol.mountURL)
                                            host.refreshDiskVolumes()
                                        } label: {
                                            Image(systemName: "eject.fill")
                                        }
                                        .buttonStyle(.borderless)
                                        .help(ZtatL10n.tr("推出宗卷", "Eject Volume"))
                                    }
                                }

                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.08))
                                        Capsule()
                                            .fill(vol.usedFraction > 0.88 ? Color.red : (vol.usedFraction > 0.72 ? Color.orange : Color.accentColor))
                                            .frame(width: max(4, geo.size.width * vol.usedFraction))
                                    }
                                }
                                .frame(height: 7)

                                if vol.purgeableBytes > 100_000_000 {
                                    Text(ZtatL10n.tr(
                                        "含可清除快照/缓存约 \(CleanerFormatters.bytes(vol.purgeableBytes))",
                                        "Includes ~\(CleanerFormatters.bytes(vol.purgeableBytes)) purgeable space"
                                    ))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }

                // Quick Stats Footer
                HStack(spacing: 12) {
                    CleanerStatTile(
                        title: ZtatL10n.tr("废纸篓哨兵", "Trash Sentinel"),
                        value: settings.sentinelEnabled ? ZtatL10n.tr("监听中", "Active") : ZtatL10n.tr("已关闭（零空闲）", "Off (Zero Idle)"),
                        symbol: "eye.trianglebadge.exclamationmark"
                    )
                    CleanerStatTile(
                        title: ZtatL10n.tr("架构瘦身累计节省", "Total Lipo Saved"),
                        value: CleanerFormatters.bytes(settings.lipoTotalSavedBytes),
                        symbol: "scissors"
                    )
                    CleanerStatTile(
                        title: ZtatL10n.tr("可还原历史", "Undo History"),
                        value: "\(DeleteHistoryStore.shared.entries.count) / 10",
                        symbol: "clock.arrow.circlepath"
                    )
                }
            }
            .padding(20)
        }
    }

    private func selectedAppDetailView(_ app: InstalledAppEntry) -> some View {
        VStack(spacing: 0) {
            // App Header Card
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable()
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(app.name)
                                .font(.title3.bold())
                            Text("v\(app.version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            CleanerMicroBadge(text: app.architecture.badgeLabel, color: app.architecture == .universal ? .purple : .secondary)
                            if let cask = app.homebrewCaskToken {
                                CleanerMicroBadge(text: "brew: \(cask)", color: .orange)
                            }
                            if app.isAppStore {
                                CleanerMicroBadge(text: "App Store", color: .blue)
                            }
                            if app.isAlreadyInTrash {
                                CleanerMicroBadge(text: ZtatL10n.tr("已在废纸篓", "In Trash"), color: .red)
                            }
                        }

                        Text(app.bundleIdentifier.isEmpty ? app.url.path : "\(app.bundleIdentifier)  ·  \(app.url.path)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)

                        if app.isNested {
                            Label(
                                ZtatL10n.tr("此应用位于子文件夹内，卸载时不会删除其父级文件夹。", "Nested inside a subfolder; parent directory will remain untouched."),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        }
                    }

                    Spacer()

                    // Per-App Utility Actions
                    HStack(spacing: 6) {
                        Button {
                            showTCCSheet = true
                        } label: {
                            Image(systemName: "lock.shield")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(ZtatL10n.tr("查看该应用的隐私权限 (TCC)", "Inspect TCC Privacy Permissions"))

                        Button {
                            showLanguagesSheet = true
                        } label: {
                            Image(systemName: "globe")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(ZtatL10n.tr("裁剪多余语言包 (.lproj)", "Prune Unused Languages (.lproj)"))

                        if app.architecture == .universal && !app.isAlreadyInTrash {
                            Button {
                                runSingleAppLipo(app)
                            } label: {
                                if isThinningSingleApp {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Label("Lipo", systemImage: "scissors")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isThinningSingleApp)
                            .help(ZtatL10n.tr("剥离非本机架构以瘦身", "Strip Non-Native Architecture Slices"))
                        }

                        Menu {
                            Button(ZtatL10n.tr("一键预设：仅重置应用数据（保留 .app）", "Reset App Preset (Keep .app, Clear Data)")) {
                                host.applyResetAppSelectionPreset()
                            }
                            Divider()
                            Button(ZtatL10n.tr("拷贝已选文件路径", "Copy Selected Paths")) {
                                let text = LeftoverScannerEngine.shared.exportPathsText(
                                    for: host.leftovers.filter(\.isSelected),
                                    appName: app.name
                                )
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                                host.showBanner(ZtatL10n.tr("已拷贝选中文件路径列表。", "Copied selected file paths."), isError: false)
                            }
                            Button(ZtatL10n.tr("导出路径清单 (.txt)…", "Export Paths List (.txt)…")) {
                                exportSelectedPathsFile(app: app)
                            }
                            Button(ZtatL10n.tr("打包备份选中文件 (.zip)…", "Archive Selected Files (.zip)…")) {
                                archiveSelectedFiles(app: app)
                            }
                            Divider()
                            Button(ZtatL10n.tr("在访达中显示应用", "Reveal App in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([app.url])
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24, height: 24)
                    }
                }

                // Controls Bar: Sensitivity override, View mode, Sort, Filter
                HStack(spacing: 8) {
                    Picker(ZtatL10n.tr("灵敏度", "Sensitivity"), selection: Binding(
                        get: { host.activeSensitivityOverride ?? settings.sensitivity },
                        set: { newVal in
                            host.activeSensitivityOverride = newVal
                            host.rescanSelectedAppLeftovers()
                        }
                    )) {
                        ForEach(CleanerSearchSensitivity.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    }
                    .controlSize(.small)
                    .frame(maxWidth: 190)

                    TextField(ZtatL10n.tr("筛选文件…", "Filter files…"), text: $fileFilterText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(maxWidth: 180)

                    Picker("", selection: $fileSortOrder) {
                        ForEach(FileSortOrder.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 100)

                    Button {
                        settings.preferCategorizedFiles.toggle()
                    } label: {
                        Image(systemName: settings.preferCategorizedFiles ? "folder.fill.badge.gearshape" : "list.bullet")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(ZtatL10n.tr("切换分类视图 / 平铺列表", "Toggle Categorized / Flat View"))

                    Spacer()

                    Button(ZtatL10n.tr("全选", "All")) { host.selectAllLeftovers(true) }
                        .controlSize(.small)
                    Button(ZtatL10n.tr("全不选", "None")) { host.selectAllLeftovers(false) }
                        .controlSize(.small)
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.025))

            Divider()

            // Leftover Files List
            if host.isScanningLeftovers {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(ZtatL10n.tr("正在深度扫描关联文件、容器与偏好设置…", "Scanning leftover files, containers, and preferences…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredLeftovers.isEmpty {
                ContentUnavailableView(
                    ZtatL10n.tr("未发现关联残留文件", "No Leftover Files Found"),
                    systemImage: "checkmark.seal",
                    description: Text(ZtatL10n.tr("可尝试调高扫描灵敏度或清除筛选词。", "Try increasing scan sensitivity or clearing the filter."))
                )
            } else {
                List {
                    if settings.preferCategorizedFiles {
                        let grouped = Dictionary(grouping: filteredLeftovers, by: \.category)
                        ForEach(LeftoverCategory.allCases.filter { grouped[$0] != nil }) { cat in
                            let catItems = grouped[cat] ?? []
                            let catBytes = catItems.reduce(Int64(0)) { $0 + $1.size }
                            let allOn = catItems.allSatisfy(\.isSelected)
                            Section {
                                if !collapsedCategories.contains(cat) {
                                    ForEach(catItems) { item in
                                        leftoverRow(item, app: app)
                                    }
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    Button {
                                        if collapsedCategories.contains(cat) {
                                            collapsedCategories.remove(cat)
                                        } else {
                                            collapsedCategories.insert(cat)
                                        }
                                    } label: {
                                        Image(systemName: collapsedCategories.contains(cat) ? "chevron.right" : "chevron.down")
                                            .font(.caption2)
                                            .frame(width: 12)
                                    }
                                    .buttonStyle(.plain)

                                    Toggle("", isOn: Binding(
                                        get: { allOn },
                                        set: { host.setCategorySelected($0, category: cat) }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)

                                    Image(systemName: cat.symbolName)
                                        .foregroundStyle(.secondary)
                                    Text(cat.title)
                                        .font(.caption.weight(.semibold))
                                    Text("(\(catItems.count))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(CleanerFormatters.bytes(catBytes))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        ForEach(filteredLeftovers) { item in
                            leftoverRow(item, app: app)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // Bottom Action Bar
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ZtatL10n.tr(
                        "已选 \(selectedLeftoverCount) / \(host.leftovers.count) 项 · 预计释放 \(CleanerFormatters.bytes(selectedLeftoverBytes))",
                        "Selected \(selectedLeftoverCount) / \(host.leftovers.count) · Reclaim \(CleanerFormatters.bytes(selectedLeftoverBytes))"
                    ))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    Text(ZtatL10n.tr("所有删除均打包移入废纸篓，支持一键还原", "All removals move to reversible Trash bundles"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !app.isAlreadyInTrash {
                    Button {
                        host.applyResetAppSelectionPreset()
                    } label: {
                        Label(ZtatL10n.tr("仅重置数据", "Reset App"), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(host.isPerformingAction || host.leftovers.count <= 1)
                }

                Button(role: .destructive) {
                    if settings.confirmBeforeDelete {
                        showConfirmDelete = true
                    } else {
                        Task { await host.executeSelectedRemoval() }
                    }
                } label: {
                    if host.isPerformingAction {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(
                            isResetOnlyMode
                                ? ZtatL10n.tr("清理选中数据", "Reset Selected Data")
                                : ZtatL10n.tr("卸载并移入废纸篓", "Uninstall to Trash"),
                            systemImage: "trash.fill"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedLeftoverCount == 0 || host.isPerformingAction)
            }
            .padding(14)
            .background(Color.primary.opacity(0.025))
        }
    }

    private func leftoverRow(_ item: LeftoverItem, app: InstalledAppEntry) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { item.isSelected },
                set: { host.setLeftoverSelected($0, id: item.id) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(item.category == .appBundle && app.isAlreadyInTrash)

            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if item.isContainerUUID {
                        CleanerMicroBadge(text: "Container", color: .blue)
                    }
                    if item.isLinkedOrphan {
                        CleanerMicroBadge(text: ZtatL10n.tr("已关联", "Linked"), color: .teal)
                    }
                    if item.isReadOnlyOrPrivileged {
                        CleanerMicroBadge(text: ZtatL10n.tr("需管理员", "Admin"), color: .orange)
                    }
                }
                Text("\(item.displayPath)  ·  \(item.matchReason)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(CleanerFormatters.bytes(item.size))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button(ZtatL10n.tr("在访达中显示", "Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button(ZtatL10n.tr("拷贝路径", "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            Button(ZtatL10n.tr("加入排除列表", "Add to Exclusions")) {
                settings.addAppExclusion(item.url.path)
                host.rescanSelectedAppLeftovers()
            }
            if item.isLinkedOrphan {
                Button(ZtatL10n.tr("取消关联此残留", "Unlink Orphan")) {
                    settings.unlinkOrphan(item.url.path, fromAppPath: app.id)
                    host.rescanSelectedAppLeftovers()
                }
            }
        }
    }

    // MARK: - Actions

    private func pickAppBundleManually() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            host.openUninstaller(for: url)
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                var resolved: URL?
                if let url = data as? URL {
                    resolved = url
                } else if let rawData = data as? Data {
                    resolved = URL(dataRepresentation: rawData, relativeTo: nil)
                }
                guard let url = resolved, url.pathExtension.lowercased() == "app" else { return }
                Task { @MainActor in
                    host.openUninstaller(for: url)
                }
            }
        }
        return accepted
    }

    private func runSingleAppLipo(_ app: InstalledAppEntry) {
        // The selected app may arrive via deep link / drag-and-drop; never rewrite protected bundles.
        if let reason = AppDiscoveryEngine.shared.restrictionReason(for: app) {
            host.appendLog(section: "Lipo", message: "\(reason) (\(app.url.path))", isError: true)
            host.showBanner(reason, isError: true)
            return
        }
        isThinningSingleApp = true
        Task {
            let result = await MachOLipoEngine.shared.thinApp(
                app,
                alsoPruneLanguages: settings.lipoPruneTranslations,
                keepLanguageCodes: settings.keepLanguageCodes,
                onLog: { msg, isErr in
                    Task { @MainActor in host.appendLog(section: "Lipo", message: msg, isError: isErr) }
                }
            )
            await MainActor.run {
                isThinningSingleApp = false
                if let err = result.errorMessage, result.reclaimedBytes == 0 {
                    host.showBanner(err, isError: true)
                } else {
                    let saved = result.reclaimedBytes + result.languagesPrunedBytes
                    host.showBanner(ZtatL10n.tr(
                        "\(app.name) 架构瘦身完成：处理 \(result.thinnedBinaryCount) 个二进制，节省 \(CleanerFormatters.bytes(saved))。",
                        "Thinned \(app.name): \(result.thinnedBinaryCount) binaries, saved \(CleanerFormatters.bytes(saved))."
                    ), isError: false)
                }
            }
            await host.refreshInstalledApps()
        }
    }

    private func exportSelectedPathsFile(app: InstalledAppEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(app.name)-leftovers.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let dest = panel.url {
            let text = LeftoverScannerEngine.shared.exportPathsText(
                for: host.leftovers.filter(\.isSelected),
                appName: app.name
            )
            try? text.write(to: dest, atomically: true, encoding: .utf8)
            host.showBanner(ZtatL10n.tr("已导出路径清单：\(dest.lastPathComponent)", "Exported paths to \(dest.lastPathComponent)"), isError: false)
        }
    }

    private func archiveSelectedFiles(app: InstalledAppEntry) {
        let chosenURLs = host.leftovers.filter(\.isSelected).map(\.url)
        guard !chosenURLs.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(app.name)-backup.zip"
        panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let dest = panel.url {
            Task {
                let (ok, err) = await LeftoverScannerEngine.shared.bundleFilesArchive(urls: chosenURLs, destinationZip: dest)
                await MainActor.run {
                    host.showBanner(
                        ok ? ZtatL10n.tr("备份压缩包已生成：\(dest.lastPathComponent)", "Created backup archive: \(dest.lastPathComponent)")
                           : (err ?? "Archive failed"),
                        isError: !ok
                    )
                }
            }
        }
    }
}

// MARK: - Per-App Sheets (TCC Permissions & Language Pruner)

struct TCCPermissionsSheet: View {
    let app: InstalledAppEntry
    @Environment(\.dismiss) private var dismiss
    @State private var records: [TCCPermissionRecord] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ZtatL10n.tr("\(app.name) — 隐私权限记录 (TCC)", "\(app.name) — TCC Privacy Permissions"))
                        .font(.headline)
                    Text(app.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(ZtatL10n.tr("关闭", "Close")) { dismiss() }
            }
            .padding()

            Divider()

            if !TCCPermissionsEngine.shared.hasFullDiskAccess() {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                    Text(ZtatL10n.tr("未授予完全磁盘访问权限，当前仅显示用户级 TCC 数据库。", "Full Disk Access not granted; showing User TCC database only."))
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
            }

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if records.isEmpty {
                ContentUnavailableView(
                    ZtatL10n.tr("暂无隐私授权记录", "No TCC Records Found"),
                    systemImage: "lock.shield",
                    description: Text(ZtatL10n.tr("该应用尚未在可读 TCC 数据库中登记权限。", "No entries found for this bundle identifier."))
                )
            } else {
                List(records) { rec in
                    HStack {
                        Image(systemName: rec.isAllowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(rec.isAllowed ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rec.serviceName).font(.body.weight(.medium))
                            Text("\(rec.scope) · \(rec.reasonLabel) · \(rec.serviceKey)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        CleanerMicroBadge(text: rec.statusLabel, color: rec.isAllowed ? .green : .red)
                    }
                }
            }
        }
        .frame(width: 560, height: 420)
        .task {
            records = await TCCPermissionsEngine.shared.queryPermissions(forBundleID: app.bundleIdentifier)
            isLoading = false
        }
    }
}

struct AppLanguagesPrunerSheet: View {
    let app: InstalledAppEntry
    @ObservedObject var host: ZtatCleanerHost
    @ObservedObject private var settings = CleanerSettingsStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var items: [LanguageBundleItem] = []
    @State private var isLoading = true
    @State private var isPruning = false

    private var selectedBytes: Int64 {
        items.filter(\.isSelectedForRemoval).reduce(0) { $0 + $1.totalSize }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ZtatL10n.tr("\(app.name) — 语言包裁剪 (.lproj)", "\(app.name) — Prune Languages (.lproj)"))
                        .font(.headline)
                    Text(ZtatL10n.tr("自动保留 Base.lproj 与您偏好的系统语言；已勾选的语言将安全移入废纸篓。", "Always preserves Base.lproj and preferred languages; checked items move safely to Trash."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(ZtatL10n.tr("关闭", "Close")) { dismiss() }
            }
            .padding()

            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    ZtatL10n.tr("未找到可裁剪的多语言包", "No Extra .lproj Bundles Found"),
                    systemImage: "globe"
                )
            } else {
                List {
                    ForEach($items) { $lang in
                        HStack {
                            Toggle("", isOn: $lang.isSelectedForRemoval)
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                            Text(lang.displayName)
                                .font(.body)
                            if lang.isPreferred {
                                CleanerMicroBadge(text: ZtatL10n.tr("偏好保留", "Preferred"), color: .green)
                            }
                            Spacer()
                            Text("\(lang.urls.count) · \(CleanerFormatters.bytes(lang.totalSize))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text(ZtatL10n.tr("预计释放：\(CleanerFormatters.bytes(selectedBytes))", "Reclaim: \(CleanerFormatters.bytes(selectedBytes))"))
                    .font(.callout.monospacedDigit())
                Spacer()
                Button(ZtatL10n.tr("移入废纸篓", "Prune Selected"), role: .destructive) {
                    isPruning = true
                    let urls = items.filter(\.isSelectedForRemoval).flatMap(\.urls)
                    Task {
                        let res = await SafeDeletionEngine.shared.trashItems(
                            urls: urls,
                            bundleLabel: "\(app.name)_Languages",
                            sourceModule: "languages"
                        )
                        await MainActor.run {
                            isPruning = false
                            host.showBanner(ZtatL10n.tr(
                                "已裁剪语言包 \(res.succeededCount) 项，释放 \(CleanerFormatters.bytes(res.freedBytes))。",
                                "Pruned \(res.succeededCount) language bundles (\(CleanerFormatters.bytes(res.freedBytes)))."
                            ), isError: false)
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isPruning || !items.contains(where: \.isSelectedForRemoval))
            }
            .padding()
        }
        .frame(width: 540, height: 420)
        .task {
            items = await MachOLipoEngine.shared.scanLanguages(in: app, keepLanguageCodes: settings.keepLanguageCodes)
            isLoading = false
        }
    }
}

// MARK: - Shared Reusable UI Components

struct CleanerMicroBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct CleanerStatTile: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct CleanerStatusBanner: View {
    let message: String
    let isError: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .orange : .green)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button { onDismiss() } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background((isError ? Color.orange : Color.green).opacity(0.12))
    }
}

struct CleanerConsoleDrawer: View {
    @ObservedObject var host: ZtatCleanerHost

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(ZtatL10n.tr("清理操作日志 (\(host.consoleLogs.count))", "Cleaner Console (\(host.consoleLogs.count))"), systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(ZtatL10n.tr("清空", "Clear")) { host.clearConsole() }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(host.consoleLogs.reversed()) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text("[\(line.section)]")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(line.message)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(line.isError ? .red : .primary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }
}
