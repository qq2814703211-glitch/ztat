// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import ZtatCore
import ZtatPowerGuard
import ZtatStatsHost
import StatusTrioCore
import ZtatIsland
import ZtatCleaner
import VorssaintToolbox

enum ZtatUnifiedNavSelection: Hashable {
    case general
    case permissions
    case powerGuard
    case taskManager
    case island(String)
    case cleaner(String)
    case statsOverview
    case statsDashboard
    case statsGlobal
    case statsModule(String)
    case statusTrio(String)
    case toolbox(String)
}

@MainActor
final class ZtatSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = ZtatSettingsWindowController()

    private var window: NSWindow?
    private let state = ZtatSettingsWindowState()
    private var languageObserver: NSObjectProtocol?

    func show(section: ZtatSettingsSection = .general) {
        show(route: ZtatSettingsRoute(section: section))
    }

    func show(route: ZtatSettingsRoute) {
        state.apply(route: route)
        state.isWindowVisible = true
        ZtatStatusTrioHost.shared.setSettingsVisible(true)

        if let existing = window {
            if existing.isMiniaturized {
                existing.deminiaturize(nil)
            }
            let isOnAnyScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(existing.frame) }
            if !isOnAnyScreen || existing.frame.width < existing.minSize.width || existing.frame.height < existing.minSize.height {
                existing.setContentSize(NSSize(width: 1080, height: 720))
                existing.center()
            }
            existing.title = ZtatL10n.tr("ztat 设置", "ztat Settings")
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ZtatUnifiedSettingsView(state: state)
        let hosting = NSHostingController(rootView: rootView)
        // CRITICAL: Prevent macOS NSHostingController from shrinking NSWindow to collapsed minSize!
        hosting.sizingOptions = []
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = ZtatL10n.tr("ztat 设置", "ztat Settings")
        win.minSize = NSSize(width: 880, height: 580)
        win.contentViewController = hosting
        // Set default centered frame BEFORE attempting restore so first launch never opens at (0, 0).
        win.setContentSize(NSSize(width: 1080, height: 720))
        win.center()
        let restored = win.setFrameUsingName("dev.ztat.settings.window")
        _ = win.setFrameAutosaveName("dev.ztat.settings.window")
        let isOnAnyScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(win.frame) }
        if !restored || !isOnAnyScreen || win.frame.width < win.minSize.width || win.frame.height < win.minSize.height {
            win.setContentSize(NSSize(width: 1080, height: 720))
            win.center()
        }
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.toolbarStyle = .unified
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win

        if languageObserver == nil {
            languageObserver = NotificationCenter.default.addObserver(
                forName: .ztatLanguageDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.window?.title = ZtatL10n.tr("ztat 设置", "ztat Settings")
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        state.isWindowVisible = false
        VitalsDashboardModel.shared.endConsumer("taskmanager.settings.embedded")
        ZtatStatsHost.shared.setEmbeddedSettingsTarget(nil)
        ZtatStatusTrioHost.shared.setSettingsVisible(false)
        ZtatCleanerHost.shared.systemDataController.cancelScan()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        state.isWindowVisible = false
        VitalsDashboardModel.shared.endConsumer("taskmanager.settings.embedded")
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        state.isWindowVisible = true
    }
}

@MainActor
private final class ZtatSettingsWindowState: ObservableObject {
    @Published var selection: ZtatUnifiedNavSelection = .general
    @Published var isWindowVisible: Bool = true

    func apply(route: ZtatSettingsRoute) {
        switch route {
        case .general:
            selection = .general
        case .permissions:
            selection = .permissions
        case .taskManager:
            selection = .taskManager
        case .powerGuard:
            selection = .powerGuard
        case .island(let sectionID):
            selection = .island(sectionID ?? "general")
        case .cleaner(let sectionID):
            selection = .cleaner(ZtatCleanerHost.normalizeSectionID(sectionID))
        case .statusTrio(let sectionID):
            selection = .statusTrio(sectionID ?? "appIcon")
        case .stats(let target):
            let normalized = ZtatStatsHost.normalizeSettingsTarget(target)
            switch normalized {
            case "overview":
                selection = .statsOverview
            case "dashboard":
                selection = .statsDashboard
            case "settings":
                selection = .statsGlobal
            default:
                selection = .statsModule(normalized)
            }
        case .toolbox(let itemID):
            let resolved = itemID ?? ZtatVorssaintHost.shared.currentSelectedToolboxItemID()
            ZtatVorssaintHost.shared.selectToolboxItem(id: resolved)
            selection = .toolbox(resolved)
        }
    }
}

private struct ZtatSearchCandidate: Identifiable {
    let id: String
    let selection: ZtatUnifiedNavSelection
    let title: String
    let group: String
    let symbol: String
    let keywords: String
}

private struct ZtatUnifiedSettingsView: View {
    @ObservedObject var state: ZtatSettingsWindowState
    @ObservedObject private var statsHost = ZtatStatsHost.shared
    @ObservedObject private var powerGuard = PowerGuardCoordinator.shared
    @ObservedObject private var islandHost = ZtatIslandHost.shared
    @ObservedObject private var cleanerHost = ZtatCleanerHost.shared
    @ObservedObject private var toolboxHost = ZtatVorssaintHost.shared
    @ObservedObject private var l10n = ZtatLocalizationStore.shared
    @ObservedObject private var taskShortcut = ZtatTaskManagerShortcutStore.shared

    @State private var searchQuery: String = ""
    @State private var collapsedGroups: Set<String> = []

    private var islandSections: [ZtatIslandSectionItem] {
        _ = l10n.revision
        return islandHost.settingsSectionItems()
    }

    private var cleanerSections: [ZtatCleanerSectionItem] {
        _ = l10n.revision
        return cleanerHost.settingsSectionItems()
    }

    private var statusSections: [ZtatStatusTrioSectionItem] {
        _ = l10n.revision
        return ZtatStatusTrioHost.shared.settingsSectionItems()
    }

    private var toolboxGroups: [ZtatToolboxNavGroup] {
        _ = (toolboxHost.navigationRevision, l10n.revision)
        return toolboxHost.sidebarGroups()
    }

    private var trimmedSearch: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var allSearchCandidates: [ZtatSearchCandidate] {
        var list: [ZtatSearchCandidate] = [
            ZtatSearchCandidate(
                id: "core:general",
                selection: .general,
                title: ZtatL10n.tr("通用", "General"),
                group: ZtatBrand.appName,
                symbol: "gearshape.fill",
                keywords: "general startup login language appearance 通用 启动 开机 语言 外观 深色 浅色"
            ),
            ZtatSearchCandidate(
                id: "core:permissions",
                selection: .permissions,
                title: ZtatL10n.tr("权限与隐私", "Permissions & Privacy"),
                group: ZtatBrand.appName,
                symbol: "hand.raised.fill",
                keywords: "permissions privacy accessibility screen recording full disk tcc 权限 隐私 辅助功能 录屏 完全磁盘访问 重置"
            ),
            ZtatSearchCandidate(
                id: "core:powerGuard",
                selection: .powerGuard,
                title: ZtatL10n.tr("保活与熄屏", "Keep-Awake & Blackout"),
                group: ZtatBrand.appName,
                symbol: "bolt.shield.fill",
                keywords: "powerguard clamshell blackout awake sleep pmset low power high power 保活 合盖 熄屏 休眠 电量模式 低电量 高能耗"
            ),
            ZtatSearchCandidate(
                id: "stats:taskManager",
                selection: .taskManager,
                title: ZtatL10n.tr("任务管理器", "Task Manager & Activity Monitor"),
                group: ZtatL10n.tr("性能监控", "Hardware Monitor"),
                symbol: "list.bullet.rectangle.portrait.fill",
                keywords: "task manager activity monitor process tree kill force cpu ram ports 任务管理器 活动监视器 进程 树状 强制退出"
            ),
            ZtatSearchCandidate(
                id: "stats:overview",
                selection: .statsOverview,
                title: ZtatL10n.tr("总览与开关", "Overview & Switches"),
                group: ZtatL10n.tr("性能监控", "Hardware Monitor"),
                symbol: "gauge.with.dots.needle.67percent",
                keywords: "stats monitor overview 性能 监控 总览 开关"
            ),
            ZtatSearchCandidate(
                id: "stats:dashboard",
                selection: .statsDashboard,
                title: ZtatL10n.tr("设备概览", "Hardware Dashboard"),
                group: ZtatL10n.tr("性能监控", "Hardware Monitor"),
                symbol: "desktopcomputer",
                keywords: "dashboard hardware specs uptime cpu ram gpu disk display 设备 硬件 概览 运行时间"
            ),
            ZtatSearchCandidate(
                id: "stats:global",
                selection: .statsGlobal,
                title: ZtatL10n.tr("全局与压测", "Global & Stress Tests"),
                group: ZtatL10n.tr("性能监控", "Hardware Monitor"),
                symbol: "slider.horizontal.3",
                keywords: "combined merge export import stress test 合并 导出 导入 压测 温度单位"
            ),
        ]

        for mod in statsHost.moduleSummaries {
            list.append(ZtatSearchCandidate(
                id: "stats:mod:\(mod.id)",
                selection: .statsModule(mod.id),
                title: mod.displayName,
                group: ZtatL10n.tr("性能监控", "Hardware Monitor"),
                symbol: mod.symbolName,
                keywords: "\(mod.id) \(mod.displayName) monitor widget popup 监控 指标 菜单栏"
            ))
        }

        for sec in islandSections {
            list.append(ZtatSearchCandidate(
                id: "island:\(sec.id)",
                selection: .island(sec.id),
                title: sec.title,
                group: ZtatL10n.tr("灵动岛", "Dynamic Island"),
                symbol: sec.symbolName,
                keywords: "\(sec.id) \(sec.title) dynamic island notch media lyrics lock screen hud osd timer calendar notes shelf terminal lottie 灵动岛 刘海 媒体 歌词 锁屏 计时器 终端 暂存架 动画 蓝牙"
            ))
        }

        for sec in cleanerSections {
            list.append(ZtatSearchCandidate(
                id: "cleaner:\(sec.id)",
                selection: .cleaner(sec.id),
                title: sec.title,
                group: ZtatL10n.tr("应用清理与卸载", "App Cleaner"),
                symbol: sec.symbolName,
                keywords: "\(sec.id) \(sec.title) \(sec.keywords)"
            ))
        }

        for sec in statusSections {
            list.append(ZtatSearchCandidate(
                id: "status:\(sec.id)",
                selection: .statusTrio(sec.id),
                title: sec.title,
                group: ZtatL10n.tr("状态与图标", "Status & Icon"),
                symbol: sec.symbolName,
                keywords: "\(sec.id) \(sec.title) status icon battery power mode wifi bluetooth audio brightness 状态 图标 电池 电量模式 网络 蓝牙 音量 亮度"
            ))
        }

        for group in toolboxGroups {
            for item in group.items {
                list.append(ZtatSearchCandidate(
                    id: "toolbox:\(item.id)",
                    selection: .toolbox(item.id),
                    title: item.title,
                    group: ZtatL10n.tr("工具箱 · \(group.title)", "Toolbox · \(group.title)"),
                    symbol: item.icon,
                    keywords: "\(item.id) \(item.title) \(group.title) toolbox 工具箱"
                ))
            }
        }

        return list
    }

    private var filteredSearchCandidates: [ZtatSearchCandidate] {
        let q = trimmedSearch.lowercased()
        guard !q.isEmpty else { return [] }
        let tokens = q.split(separator: " ").map(String.init)
        return allSearchCandidates.filter { candidate in
            let haystack = "\(candidate.title) \(candidate.group) \(candidate.keywords)".lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        let _ = l10n.revision
        NavigationSplitView {
            List(selection: $state.selection) {
                if !trimmedSearch.isEmpty {
                    Section(ZtatL10n.tr("搜索结果 (\(filteredSearchCandidates.count))", "Results (\(filteredSearchCandidates.count))")) {
                        if filteredSearchCandidates.isEmpty {
                            Text(ZtatL10n.tr("未找到匹配设置项", "No matching settings"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(filteredSearchCandidates) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: item.symbol)
                                        .frame(width: 16)
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title)
                                        Text(item.group)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(item.selection)
                            }
                        }
                    }
                } else {
                    // 1. Core
                    Section(ZtatBrand.appName) {
                        Label(ZtatL10n.tr("通用", "General"), systemImage: "gearshape.fill")
                            .tag(ZtatUnifiedNavSelection.general)

                        Label(ZtatL10n.tr("权限与隐私", "Permissions & Privacy"), systemImage: "hand.raised.fill")
                            .tag(ZtatUnifiedNavSelection.permissions)

                        HStack {
                            Label(ZtatL10n.tr("保活与熄屏", "Keep-Awake & Blackout"), systemImage: "bolt.shield.fill")
                            Spacer(minLength: 4)
                            if powerGuard.isAnyGuardActive {
                                Circle()
                                    .fill(powerGuard.isBlackoutActive ? Color.indigo : (powerGuard.isClamshellLocked ? Color.orange : Color.green))
                                    .frame(width: 7, height: 7)
                            }
                        }
                        .tag(ZtatUnifiedNavSelection.powerGuard)
                    }

                    // 2. Dynamic Island (Native Atoll Engine)
                    Section(isExpanded: groupExpandedBinding("island")) {
                        ForEach(islandSections) { sec in
                            HStack(spacing: 6) {
                                Label(sec.title, systemImage: sec.symbolName)
                                if sec.id == "general", islandHost.isEnabled {
                                    Spacer(minLength: 4)
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 6, height: 6)
                                }
                            }
                            .tag(ZtatUnifiedNavSelection.island(sec.id))
                        }
                    } header: {
                        Text(ZtatL10n.tr("灵动岛", "Dynamic Island"))
                    }

                    // 3. Status & Menu Bar Icon
                    Section(isExpanded: groupExpandedBinding("status")) {
                        ForEach(statusSections) { sec in
                            Label(sec.title, systemImage: sec.symbolName)
                                .tag(ZtatUnifiedNavSelection.statusTrio(sec.id))
                        }
                    } header: {
                        Text(ZtatL10n.tr("状态与菜单栏图标", "Status & Menu Bar Icon"))
                    }

                    // 3. Hardware Monitor
                    Section(isExpanded: groupExpandedBinding("stats")) {
                        Label(ZtatL10n.tr("任务管理器", "Task Manager"), systemImage: "list.bullet.rectangle.portrait.fill")
                            .tag(ZtatUnifiedNavSelection.taskManager)

                        HStack {
                            Label(ZtatL10n.tr("总览与开关", "Overview & Switches"), systemImage: "gauge.with.dots.needle.67percent")
                            Spacer(minLength: 4)
                            if statsHost.enabledModuleCount > 0 {
                                Text("\(statsHost.enabledModuleCount)")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(ZtatUnifiedNavSelection.statsOverview)

                        Label(ZtatL10n.tr("设备概览", "Hardware Dashboard"), systemImage: "desktopcomputer")
                            .tag(ZtatUnifiedNavSelection.statsDashboard)

                        Label(ZtatL10n.tr("全局与压测", "Global & Stress Tests"), systemImage: "slider.horizontal.3")
                            .tag(ZtatUnifiedNavSelection.statsGlobal)

                        ForEach(statsHost.moduleSummaries) { mod in
                            HStack(spacing: 6) {
                                Label(mod.displayName, systemImage: mod.symbolName)
                                Spacer(minLength: 4)
                                if mod.isEnabled {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 6, height: 6)
                                }
                            }
                            .tag(ZtatUnifiedNavSelection.statsModule(mod.id))
                        }
                    } header: {
                        Text(ZtatL10n.tr("性能监控", "Hardware Monitor"))
                    }

                    // 3.5 App Cleaner & Uninstaller (Pearcleaner-inspired clean-room suite)
                    Section(isExpanded: groupExpandedBinding("cleaner")) {
                        ForEach(cleanerSections) { sec in
                            Label(sec.title, systemImage: sec.symbolName)
                                .tag(ZtatUnifiedNavSelection.cleaner(sec.id))
                        }
                    } header: {
                        Text(ZtatL10n.tr("应用清理与卸载", "App Cleaner"))
                    }

                    // 4. Toolbox
                    ForEach(toolboxGroups) { group in
                        Section(isExpanded: groupExpandedBinding("toolbox:\(group.id)")) {
                            ForEach(group.items) { item in
                                Label(item.title, systemImage: item.icon)
                                    .tag(ZtatUnifiedNavSelection.toolbox(item.id))
                            }
                        } header: {
                            Text(ZtatL10n.tr("工具箱 · \(group.title)", "Toolbox · \(group.title)"))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchQuery, placement: .sidebar, prompt: Text(ZtatL10n.tr("搜索设置…", "Search Settings…")))
            .navigationSplitViewColumnWidth(min: 225, ideal: 250, max: 300)
        } detail: {
            if state.isWindowVisible {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: state.selection) { _, newValue in
            if case .toolbox(let itemID) = newValue {
                toolboxHost.selectToolboxItem(id: itemID)
            }
            if !isStatsEmbeddedSelection(newValue) {
                statsHost.setEmbeddedSettingsTarget(nil)
            }
        }
        .onChange(of: toolboxHost.activeToolboxItemID) { _, newItemID in
            // Two-way sidebar sync when an internal Toolbox link navigates to another tool page
            if case .toolbox(let currentID) = state.selection, currentID != newItemID {
                state.selection = .toolbox(newItemID)
            }
        }
    }

    private func isStatsEmbeddedSelection(_ sel: ZtatUnifiedNavSelection) -> Bool {
        switch sel {
        case .statsDashboard, .statsGlobal, .statsModule:
            return true
        default:
            return false
        }
    }

    private func groupExpandedBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(key) },
            set: { expanded in
                if expanded {
                    collapsedGroups.remove(key)
                } else {
                    collapsedGroups.insert(key)
                }
            }
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        switch state.selection {
        case .general:
            ZtatGeneralSettingsView(onNavigate: { route in
                state.apply(route: route)
            })
        case .permissions:
            toolboxHost.makePermissionsPortalView()
        case .powerGuard:
            PowerGuardSettingsView(coordinator: powerGuard)
        case .taskManager:
            ZtatTaskManagerView(
                model: VitalsDashboardModel.shared,
                consumerID: "taskmanager.settings.embedded",
                isEmbeddedInSettings: true,
                shortcutDisplayHint: taskShortcut.displayString,
                onOpenStandaloneWindow: {
                    ZtatTaskManagerWindowController.shared.show()
                }
            )
        case .island(let sectionID):
            VStack(spacing: 0) {
                if sectionID == "general" {
                    HStack(spacing: 12) {
                        Image(systemName: "macbook")
                            .font(.title3)
                            .foregroundStyle(islandHost.isEnabled ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ZtatL10n.tr("启用原生灵动岛", "Enable Native Dynamic Island"))
                                .font(.headline)
                            Text(ZtatL10n.tr(
                                "关闭后将彻底释放灵动岛窗口与后台监听；开启即刻生效。",
                                "Disabling releases all Dynamic Island windows and monitors immediately."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if islandHost.isEnabled {
                            Button(ZtatL10n.tr("展开/收起", "Toggle")) {
                                islandHost.toggleNotchOpen()
                            }
                            .controlSize(.small)
                        }
                        Toggle("", isOn: Binding(
                            get: { islandHost.isEnabled },
                            set: { islandHost.setEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    Divider()
                }
                islandHost.makeSettingsDetailView(sectionID: sectionID)
                    .id(sectionID)
            }
        case .cleaner(let sectionID):
            cleanerHost.makeSettingsDetailView(sectionID: sectionID)
                .id(sectionID)
        case .statsOverview:
            StatsSettingsContainerView(host: statsHost) { target in
                state.apply(route: .stats(target: target))
            }
        case .statsDashboard:
            StatsEmbeddedTargetView(target: "dashboard", host: statsHost)
        case .statsGlobal:
            StatsEmbeddedTargetView(target: "settings", host: statsHost)
        case .statsModule(let modID):
            StatsEmbeddedTargetView(target: modID, host: statsHost)
        case .statusTrio(let sectionID):
            ZtatStatusTrioHost.shared.makeSettingsDetailView(sectionID: sectionID)
                .id(sectionID)
        case .toolbox:
            toolboxHost.makeDetailOnlySettingsView()
        }
    }
}

private struct ZtatGeneralSettingsView: View {
    let onNavigate: (ZtatSettingsRoute) -> Void

    @ObservedObject private var loginItem = ZtatLoginItemStore.shared
    @ObservedObject private var l10n = ZtatLocalizationStore.shared
    @ObservedObject private var appearance = ZtatAppearanceStore.shared
    @ObservedObject private var statsHost = ZtatStatsHost.shared
    @ObservedObject private var powerGuard = PowerGuardCoordinator.shared

    var body: some View {
        let _ = l10n.revision
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(ZtatBrand.appName) \(ZtatBrand.version)")
                            .font(.headline)
                        Text(ZtatL10n.tr(
                            "一站式 macOS 菜单栏状态控制、原生灵动岛、保活防休眠、硬件性能监控与系统效率工具箱。",
                            "Unified macOS menu bar control center for status, native Dynamic Island, keep-awake power guard, hardware monitoring, and productivity tools."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section(ZtatL10n.tr("启动与全局外观", "Startup & Appearance")) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        ZtatL10n.tr("开机自动启动 ztat", "Launch ztat at Login"),
                        isOn: Binding(
                            get: { loginItem.isEnabled || loginItem.requiresApproval },
                            set: { loginItem.setEnabled($0) }
                        )
                    )
                    if loginItem.requiresApproval {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(ZtatL10n.tr(
                                "已在系统注册登录项，请在“系统设置 → 登录项与扩展”中允许 ztat。",
                                "Login item registered; approve ztat in System Settings → Login Items."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Spacer()
                            Button(ZtatL10n.tr("打开登录项", "Open Login Items")) {
                                loginItem.openLoginItemsSettings()
                            }
                            .controlSize(.small)
                        }
                    } else if !loginItem.isRunningFromApplications {
                        Text(ZtatL10n.tr(
                            "提示：将 ztat.app 安装在「应用程序」文件夹可确保开机启动与系统权限稳定生效。",
                            "Tip: Run ztat.app from /Applications for reliable Login Item registration and macOS permissions."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else if let err = loginItem.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Picker(ZtatL10n.tr("应用语言", "Language"), selection: $l10n.preference) {
                    ForEach(ZtatLanguagePreference.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }

                Picker(ZtatL10n.tr("界面外观", "Appearance"), selection: $appearance.appearance) {
                    ForEach(ZtatAppearancePreference.allCases) { opt in
                        Text(opt.displayName).tag(opt)
                    }
                }
                .pickerStyle(.segmented)
            }

            ZtatTaskManagerShortcutSettingsSection()

            Section(ZtatL10n.tr("快捷入口", "Quick Access")) {
                HStack(spacing: 8) {
                    Button(ZtatL10n.tr("任务管理器", "Task Manager")) {
                        onNavigate(.taskManager)
                    }
                    Button(ZtatL10n.tr("权限与隐私", "Permissions")) {
                        onNavigate(.permissions)
                    }
                    Button(ZtatL10n.tr("灵动岛", "Island")) {
                        onNavigate(.island(sectionID: "general"))
                    }
                    Button(ZtatL10n.tr("应用卸载清理", "App Cleaner")) {
                        onNavigate(.cleaner(sectionID: "apps"))
                    }
                    Button(ZtatL10n.tr("状态与图标", "Status & Icon")) {
                        onNavigate(.statusTrio(sectionID: "appIcon"))
                    }
                    Button(ZtatL10n.tr("保活 (\(powerGuard.currentSnapshot.summaryLabel))", "PowerGuard")) {
                        onNavigate(.powerGuard)
                    }
                    Button(ZtatL10n.tr("性能监控 (\(statsHost.enabledModuleCount))", "Monitor (\(statsHost.enabledModuleCount))")) {
                        onNavigate(.stats(target: "overview"))
                    }
                    Button(ZtatL10n.tr("工具箱", "Toolbox")) {
                        onNavigate(.toolbox(itemID: nil))
                    }
                }
            }

            Section(ZtatL10n.tr("关于与许可", "About & License")) {
                LabeledContent(ZtatL10n.tr("标识符", "Bundle ID"), value: ZtatBrand.activeBundleIdentifier)
                LabeledContent(ZtatL10n.tr("安装位置", "Location"), value: Bundle.main.bundlePath)
                Text(ZtatL10n.tr(
                    "ztat 遵循 GPL-3.0-or-later 开源许可发布，所有检测、监控与控制均在本地运行，零云端遥测。",
                    "ztat is released under GPL-3.0-or-later. All monitoring and system controls run strictly locally with zero telemetry."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loginItem.refresh()
        }
    }
}
