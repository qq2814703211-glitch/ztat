// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import ZtatCore
import ZtatPowerGuard
import ZtatStatsHost
import StatusTrioCore
import VorssaintToolbox

enum ZtatUnifiedNavSelection: Hashable {
    case general
    case powerGuard
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

    func show(section: ZtatSettingsSection = .general) {
        show(route: ZtatSettingsRoute(section: section))
    }

    func show(route: ZtatSettingsRoute) {
        state.apply(route: route)

        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ZtatUnifiedSettingsView(state: state)
        let hosting = NSHostingController(rootView: rootView)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = ZtatL10n.tr("ztat 统一设置", "ztat Settings")
        win.contentViewController = hosting
        win.minSize = NSSize(width: 800, height: 540)
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.toolbarStyle = .unified
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func windowWillClose(_ notification: Notification) {
        ZtatStatsHost.shared.setEmbeddedSettingsTarget(nil)
    }
}

@MainActor
private final class ZtatSettingsWindowState: ObservableObject {
    @Published var selection: ZtatUnifiedNavSelection = .general

    func apply(route: ZtatSettingsRoute) {
        switch route {
        case .general:
            selection = .general
        case .powerGuard:
            selection = .powerGuard
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
    @ObservedObject private var vorssaintHost = ZtatVorssaintHost.shared

    @State private var searchQuery: String = ""
    @State private var collapsedGroups: Set<String> = []

    private var statusTrioSections: [ZtatStatusTrioSectionItem] {
        ZtatStatusTrioHost.shared.settingsSectionItems()
    }

    private var toolboxGroups: [ZtatToolboxNavGroup] {
        _ = vorssaintHost.navigationRevision
        return vorssaintHost.sidebarGroups()
    }

    private var trimmedSearch: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var allSearchCandidates: [ZtatSearchCandidate] {
        var list: [ZtatSearchCandidate] = [
            ZtatSearchCandidate(
                id: "general",
                selection: .general,
                title: ZtatL10n.tr("通用与菜单栏", "General & Menu Bar"),
                group: "ztat",
                symbol: "slider.horizontal.3",
                keywords: "general startup login menubar 通用 开机 启动 菜单栏 关于"
            ),
            ZtatSearchCandidate(
                id: "powerGuard",
                selection: .powerGuard,
                title: ZtatL10n.tr("合盖保活与熄屏", "PowerGuard & Blackout"),
                group: "ztat",
                symbol: "bolt.shield.fill",
                keywords: "powerguard budhold clamshell blackout awake sleep pmset 保活 合盖 熄屏 休眠 防睡眠 远程"
            ),
            ZtatSearchCandidate(
                id: "stats:overview",
                selection: .statsOverview,
                title: ZtatL10n.tr("监控总览与开关", "Monitor Overview"),
                group: ZtatL10n.tr("性能监控", "Hardware Stats"),
                symbol: "gauge.with.dots.needle.67percent",
                keywords: "stats monitor hardware combine 性能 监控 合并 温度"
            ),
            ZtatSearchCandidate(
                id: "stats:dashboard",
                selection: .statsDashboard,
                title: ZtatL10n.tr("设备与硬件概览", "Hardware Dashboard"),
                group: ZtatL10n.tr("性能监控", "Hardware Stats"),
                symbol: "desktopcomputer",
                keywords: "dashboard device specs uptime 仪表盘 硬件 规格 运行时间"
            ),
            ZtatSearchCandidate(
                id: "stats:settings",
                selection: .statsGlobal,
                title: ZtatL10n.tr("全局与压力测试", "Global & Stress Tests"),
                group: ZtatL10n.tr("性能监控", "Hardware Stats"),
                symbol: "wrench.and.screwdriver",
                keywords: "stats settings export import stress test 压力测试 导入 导出 合并间距"
            ),
        ]

        for mod in statsHost.moduleSummaries {
            list.append(ZtatSearchCandidate(
                id: "stats:\(mod.id)",
                selection: .statsModule(mod.id),
                title: mod.displayName,
                group: ZtatL10n.tr("性能监控", "Hardware Stats"),
                symbol: mod.symbolName,
                keywords: "\(mod.id) \(mod.displayName) stats monitor widget popup 监控 组件"
            ))
        }

        for sec in statusTrioSections {
            list.append(ZtatSearchCandidate(
                id: "st:\(sec.id)",
                selection: .statusTrio(sec.id),
                title: sec.title,
                group: ZtatL10n.tr("状态图标", "Status Icon"),
                symbol: sec.symbolName,
                keywords: "\(sec.id) \(sec.title) status trio icon battery wifi bluetooth audio 状态 图标 面板"
            ))
        }

        for group in toolboxGroups {
            for item in group.items {
                list.append(ZtatSearchCandidate(
                    id: "tb:\(item.id)",
                    selection: .toolbox(item.id),
                    title: item.title,
                    group: group.title,
                    symbol: item.icon,
                    keywords: "\(item.id) \(item.title) \(group.title) toolbox vorssaint 工具箱"
                ))
            }
        }

        return list
    }

    private var filteredSearchCandidates: [ZtatSearchCandidate] {
        let q = trimmedSearch.lowercased()
        guard !q.isEmpty else { return [] }
        return allSearchCandidates.filter { candidate in
            candidate.title.lowercased().contains(q)
                || candidate.group.lowercased().contains(q)
                || candidate.keywords.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<ZtatUnifiedNavSelection?>(
                get: { state.selection },
                set: { if let v = $0 { state.selection = v } }
            )) {
                if !trimmedSearch.isEmpty {
                    Section(ZtatL10n.tr("搜索结果 (\(filteredSearchCandidates.count))", "Results (\(filteredSearchCandidates.count))")) {
                        if filteredSearchCandidates.isEmpty {
                            Text(ZtatL10n.tr("未找到匹配设置项", "No matching settings"))
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        } else {
                            ForEach(filteredSearchCandidates) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: item.symbol)
                                        .frame(width: 18)
                                        .foregroundStyle(.tint)
                                    Text(item.title)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(item.group)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                .tag(item.selection)
                            }
                        }
                    }
                } else {
                    // 1. Core ztat Overview & PowerGuard
                    Section("ztat") {
                        Label(ZtatL10n.tr("通用与菜单栏", "General & Menu Bar"), systemImage: "slider.horizontal.3")
                            .tag(ZtatUnifiedNavSelection.general)

                        HStack(spacing: 8) {
                            Label(ZtatL10n.tr("合盖保活与熄屏", "PowerGuard & Blackout"), systemImage: "bolt.shield.fill")
                            Spacer(minLength: 4)
                            if powerGuard.isAnyGuardActive {
                                Circle()
                                    .fill(powerGuard.isBlackoutActive ? Color.indigo : (powerGuard.isClamshellLocked ? Color.orange : Color.green))
                                    .frame(width: 7, height: 7)
                            }
                        }
                        .tag(ZtatUnifiedNavSelection.powerGuard)
                    }

                    // 2. Hardware Performance Monitor (Stats natively embedded, zero pop-out window)
                    collapsibleSection(
                        id: "stats",
                        title: ZtatL10n.tr("性能监控", "Hardware Stats")
                    ) {
                        HStack(spacing: 8) {
                            Label(ZtatL10n.tr("总览与开关", "Overview & Toggles"), systemImage: "gauge.with.dots.needle.67percent")
                            Spacer(minLength: 4)
                            if statsHost.enabledModuleCount > 0 {
                                Text("\(statsHost.enabledModuleCount)")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .tag(ZtatUnifiedNavSelection.statsOverview)

                        Label(ZtatL10n.tr("设备与硬件概览", "Hardware Dashboard"), systemImage: "desktopcomputer")
                            .tag(ZtatUnifiedNavSelection.statsDashboard)

                        Label(ZtatL10n.tr("全局与压力测试", "Global & Stress Tests"), systemImage: "wrench.and.screwdriver")
                            .tag(ZtatUnifiedNavSelection.statsGlobal)

                        ForEach(statsHost.moduleSummaries) { item in
                            HStack(spacing: 8) {
                                Label(item.displayName, systemImage: item.symbolName)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if item.isEnabled {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 6, height: 6)
                                }
                            }
                            .tag(ZtatUnifiedNavSelection.statsModule(item.id))
                        }
                    }

                    // 3. Unified Status Icon & Panel (Status Trio flattened, zero nested sidebar)
                    collapsibleSection(
                        id: "statusTrio",
                        title: ZtatL10n.tr("状态图标与面板", "Status Icon & Panel")
                    ) {
                        ForEach(statusTrioSections) { item in
                            Label(item.title, systemImage: item.symbolName)
                                .tag(ZtatUnifiedNavSelection.statusTrio(item.id))
                        }
                    }

                    // 4. Utility Toolbox (Vorssaint deduplicated groups flattened, zero nested sidebar)
                    ForEach(toolboxGroups) { group in
                        collapsibleSection(
                            id: "toolbox-\(group.id)",
                            title: ZtatL10n.tr("工具箱 · \(group.title)", "Toolbox · \(group.title)")
                        ) {
                            ForEach(group.items) { item in
                                Label(item.title, systemImage: item.icon)
                                    .lineLimit(1)
                                    .tag(ZtatUnifiedNavSelection.toolbox(item.id))
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(
                text: $searchQuery,
                placement: .sidebar,
                prompt: ZtatL10n.tr("搜索全部设置…", "Search all settings…")
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 242, max: 280)
        } detail: {
            detailView(for: state.selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: state.selection) { _, newSelection in
            if case .toolbox(let itemID) = newSelection {
                vorssaintHost.selectToolboxItem(id: itemID)
            }
            switch newSelection {
            case .statsModule, .statsDashboard, .statsGlobal:
                break
            default:
                statsHost.setEmbeddedSettingsTarget(nil)
            }
        }
        .onAppear {
            statsHost.refreshSummaries()
        }
    }

    @ViewBuilder
    private func collapsibleSection<Content: View>(
        id: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = collapsedGroups.contains(id)
        Section {
            if !isCollapsed {
                content()
            }
        } header: {
            Button {
                if !collapsedGroups.insert(id).inserted {
                    collapsedGroups.remove(id)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text(title)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func detailView(for selection: ZtatUnifiedNavSelection) -> some View {
        switch selection {
        case .general:
            ZtatGeneralSettingsView(onNavigate: { route in
                state.apply(route: route)
            })
        case .powerGuard:
            PowerGuardSettingsView()
        case .statusTrio(let sectionID):
            ZtatStatusTrioHost.shared.makeSettingsDetailView(sectionID: sectionID)
        case .statsOverview:
            StatsSettingsContainerView(onSelectTarget: { target in
                state.apply(route: .stats(target: target))
            })
        case .statsDashboard:
            StatsEmbeddedTargetView(target: "dashboard")
        case .statsGlobal:
            StatsEmbeddedTargetView(target: "settings")
        case .statsModule(let moduleID):
            StatsEmbeddedTargetView(target: moduleID)
        case .toolbox(let itemID):
            ZtatVorssaintHost.shared.makeDetailOnlySettingsView()
                .onAppear {
                    ZtatVorssaintHost.shared.selectToolboxItem(id: itemID)
                }
        }
    }
}

private struct ZtatGeneralSettingsView: View {
    let onNavigate: (ZtatSettingsRoute) -> Void
    @ObservedObject private var loginItem = ZtatLoginItemManager.shared
    @ObservedObject private var statsHost = ZtatStatsHost.shared
    @ObservedObject private var powerGuard = PowerGuardCoordinator.shared

    var body: some View {
        Form {
            Section(ZtatL10n.tr("应用与启动", "Application & Startup")) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ZtatBrand.appName) \(ZtatBrand.version)")
                            .font(.headline)
                        Text(ZtatL10n.tr(
                            "基于 Vorssaint 二开整合 Status Trio · Stats · PowerGuard 的统一 macOS 精炼工具箱",
                            "Unified macOS utility suite combining Status Trio, Stats, PowerGuard, and curated Vorssaint tools"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Toggle(
                    ZtatL10n.tr("开机自动启动 ztat", "Launch ztat at Login"),
                    isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) }
                    )
                )
            }

            Section(ZtatL10n.tr("菜单栏与统一界面契约", "Unified Menu Bar & Settings Contract")) {
                LabeledContent(
                    ZtatL10n.tr("唯一主菜单栏图标", "Primary Menu Bar Icon"),
                    value: ZtatL10n.tr("Status Trio 自适应三合一图标（点击展开统一控制中心）", "Status Trio adaptive icon (opens unified Hub)")
                )
                LabeledContent(
                    ZtatL10n.tr("独立性能监控指标", "Dedicated Performance Metrics"),
                    value: statsHost.enabledModuleCount == 0
                        ? ZtatL10n.tr("当前未开启（点击下方进入配置）", "None active (enable metrics in Hardware Stats)")
                        : ZtatL10n.tr("已开启 \(statsHost.enabledModuleCount) 项监控指标（弹窗齿轮直达当前统一设置）", "\(statsHost.enabledModuleCount) metric(s) active (settings open here)")
                )
                LabeledContent(
                    ZtatL10n.tr("保活与工具箱图标", "PowerGuard & Toolbox Icons"),
                    value: ZtatL10n.tr("已收敛至统一控制中心与本设置窗口，零独立窗口割裂", "Embedded in Unified Hub & single Settings window")
                )
            }

            Section(ZtatL10n.tr("快速跳转", "Quick Navigation")) {
                HStack(spacing: 10) {
                    Button(ZtatL10n.tr("菜单栏状态图标", "Status Icon")) {
                        onNavigate(.statusTrio(sectionID: "appIcon"))
                    }
                    Button(ZtatL10n.tr("保活与熄屏 (\(powerGuard.currentSnapshot.summaryLabel))", "PowerGuard")) {
                        onNavigate(.powerGuard)
                    }
                    Button(ZtatL10n.tr("性能监控指标", "Hardware Stats")) {
                        onNavigate(.stats(target: "overview"))
                    }
                    Button(ZtatL10n.tr("系统工具箱", "Utility Toolbox")) {
                        onNavigate(.toolbox(itemID: nil))
                    }
                }
            }

            Section(ZtatL10n.tr("开源许可与架构", "License & Architecture")) {
                Text(ZtatL10n.tr(
                    "ztat 遵循 GPL-3.0-or-later 许可发布。已移除各上游重叠功能、独立设置窗口、后台遥测与重复轮询，并针对 Apple Silicon 与 macOS Liquid Glass 进行性能调优。",
                    "ztat is licensed under GPL-3.0-or-later. Overlapping modules, separate upstream settings windows, telemetry, and duplicate polling loops have been eliminated and optimized for Apple Silicon."
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
