// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Full macOS Activity Monitor Replacement + Vitals Task Manager.
// Provides 8 tabs (CPU, Memory, Energy, Disk, Network & Ports, GPU & ANE, Dev/Agents/Containers, Hardware Overview),
// 3 process views (App Grouped, Hierarchical Tree, Flat List), 7 scopes, sortable columns,
// live bottom telemetry strip, tabbed deep Process Inspector (Args/Env, Open Files/Sockets, Code Signature,
// Live Call-Stack Sampling), Unix Signal sender, and CSV snapshot export.

import AppKit
import Combine
import Darwin
import StatsKit
import SwiftUI
import ZtatCore

public enum ZtatTaskManagerTab: Int, CaseIterable, Identifiable, Sendable {
    case cpu = 0
    case memory = 1
    case energy = 2
    case disk = 3
    case network = 4
    case gpu = 5
    case dev = 6
    case hardware = 7

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .cpu:      return "CPU"
        case .memory:   return ZtatL10n.tr("内存", "Memory")
        case .energy:   return ZtatL10n.tr("能耗", "Energy")
        case .disk:     return ZtatL10n.tr("磁盘", "Disk")
        case .network:  return ZtatL10n.tr("网络与端口", "Network")
        case .gpu:      return "GPU / ANE"
        case .dev:      return ZtatL10n.tr("开发与容器", "Dev")
        case .hardware: return ZtatL10n.tr("硬件总览", "Hardware")
        }
    }

    public var symbol: String {
        switch self {
        case .cpu:      return "cpu"
        case .memory:   return "memorychip"
        case .energy:   return "bolt.fill"
        case .disk:     return "internaldrive"
        case .network:  return "network"
        case .gpu:      return "rectangle.3.group"
        case .dev:      return "sparkles"
        case .hardware: return "square.grid.2x2.fill"
        }
    }

    public var defaultSortColumn: Int {
        switch self {
        case .cpu:    return 0
        case .memory: return 1
        case .energy: return 2
        case .disk:   return 3
        default:      return 0
        }
    }
}

private enum InspectorSubTab: Int, CaseIterable, Identifiable {
    case overview = 0
    case argsEnv = 1
    case openFiles = 2
    case signature = 3
    case sample = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overview:  return ZtatL10n.tr("概览", "Info")
        case .argsEnv:   return ZtatL10n.tr("命令/环境", "Args")
        case .openFiles: return ZtatL10n.tr("文件/端口", "Files")
        case .signature: return ZtatL10n.tr("签名", "Sign")
        case .sample:    return ZtatL10n.tr("采样", "Sample")
        }
    }
}

private enum KillConfirmationTarget: Identifiable {
    case process(VitalsProcessItem)
    case group(VitalsAppGroup)

    var id: String {
        switch self {
        case .process(let item): return "proc-\(item.id)"
        case .group(let group):  return "grp-\(group.id)"
        }
    }
}

public struct ZtatTaskManagerView: View {
    @ObservedObject public var model: VitalsDashboardModel
    public let consumerID: String
    public let isEmbeddedInSettings: Bool
    public let shortcutDisplayHint: String
    public let onOpenStandaloneWindow: (() -> Void)?

    @State private var activeTab: ZtatTaskManagerTab = .cpu
    @State private var selectedProcessID: Int32? = nil
    @State private var lastInspectedPID: Int32? = nil
    @State private var showingInspector: Bool = false
    @State private var inspectorTab: InspectorSubTab = .overview
    @State private var confirmKillTarget: KillConfirmationTarget? = nil
    @State private var hardwareSubPane: VitalsPane = .overview
    @State private var fileFilterQuery: String = ""

    public init(
        model: VitalsDashboardModel? = nil,
        consumerID: String = "taskmanager.default",
        isEmbeddedInSettings: Bool = false,
        shortcutDisplayHint: String = "⌃⇧⎋",
        onOpenStandaloneWindow: (() -> Void)? = nil
    ) {
        self.model = model ?? VitalsDashboardModel.shared
        self.consumerID = consumerID
        self.isEmbeddedInSettings = isEmbeddedInSettings
        self.shortcutDisplayHint = shortcutDisplayHint
        self.onOpenStandaloneWindow = onOpenStandaloneWindow
    }

    private var hw: VitalsHardwareSnapshot { model.hardware }

    private var selectedProcessItem: VitalsProcessItem? {
        guard let id = selectedProcessID else { return nil }
        return model.processes.first(where: { $0.id == id })
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabAndActionBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))

            Divider()

            if let feedback = model.actionFeedback {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
                    Text(feedback).font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.10))
                Divider()
            }

            mainTabBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            bottomTelemetryStrip
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.025))
        }
        .onAppear {
            model.beginConsumer(consumerID)
        }
        .onDisappear {
            model.endConsumer(consumerID)
        }
        .onChange(of: activeTab) { _, newTab in
            if [.cpu, .memory, .energy, .disk].contains(newTab) {
                model.sortColumn = newTab.defaultSortColumn
                model.sortAscending = false
            }
        }
        .onChange(of: selectedProcessID) { _, newPID in
            if showingInspector, let pid = newPID, pid != lastInspectedPID {
                lastInspectedPID = pid
                model.loadDeepDetails(for: pid)
            }
        }
        .onChange(of: model.lastUpdatedAt) { _, _ in
            if let pid = selectedProcessID, !model.processes.contains(where: { $0.id == pid }) {
                selectedProcessID = nil
                if showingInspector {
                    showingInspector = false
                    lastInspectedPID = nil
                }
            }
        }
        .alert(item: $confirmKillTarget) { target in
            switch target {
            case .process(let item):
                return Alert(
                    title: Text(ZtatL10n.tr("强制退出进程", "Force Quit Process")),
                    message: Text(ZtatL10n.tr(
                        "确定要向「\(item.name)」(PID: \(item.id)) 发送 SIGKILL 强制终止吗？未保存的数据将会丢失。",
                        "Send SIGKILL to \"\(item.name)\" (PID: \(item.id))? Any unsaved data will be lost."
                    )),
                    primaryButton: .destructive(Text(ZtatL10n.tr("强制退出", "Force Quit"))) {
                        model.terminateProcess(item, force: true)
                    },
                    secondaryButton: .cancel(Text(ZtatL10n.tr("取消", "Cancel")))
                )
            case .group(let group):
                return Alert(
                    title: Text(ZtatL10n.tr("强制退出整个应用组", "Force Quit App Group")),
                    message: Text(ZtatL10n.tr(
                        "确定要强制终止「\(group.name)」及其全部 \(group.processCount) 个进程吗？",
                        "Force quit \"\(group.name)\" and all \(group.processCount) processes?"
                    )),
                    primaryButton: .destructive(Text(ZtatL10n.tr("强制退出", "Force Quit"))) {
                        model.terminateAppGroup(group, force: true)
                    },
                    secondaryButton: .cancel(Text(ZtatL10n.tr("取消", "Cancel")))
                )
            }
        }
        // Hidden keyboard shortcut buttons (⌘1..⌘8, ⌘I, ⌘R)
        .background(keyboardShortcutsLayer)
    }

    private var keyboardShortcutsLayer: some View {
        Group {
            Button("") { activeTab = .cpu }.keyboardShortcut("1", modifiers: .command)
            Button("") { activeTab = .memory }.keyboardShortcut("2", modifiers: .command)
            Button("") { activeTab = .energy }.keyboardShortcut("3", modifiers: .command)
            Button("") { activeTab = .disk }.keyboardShortcut("4", modifiers: .command)
            Button("") { activeTab = .network }.keyboardShortcut("5", modifiers: .command)
            Button("") { activeTab = .gpu }.keyboardShortcut("6", modifiers: .command)
            Button("") { activeTab = .dev }.keyboardShortcut("7", modifiers: .command)
            Button("") { activeTab = .hardware }.keyboardShortcut("8", modifiers: .command)
            Button("") { toggleInspector() }.keyboardShortcut("i", modifiers: .command)
            Button("") { model.refresh(forceSlowScans: true) }.keyboardShortcut("r", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func openInspector(for pid: Int32, tab: InspectorSubTab? = nil, runSample: Bool = false) {
        selectedProcessID = pid
        if let tab {
            inspectorTab = tab
        }
        withAnimation(.easeInOut(duration: 0.16)) {
            showingInspector = true
        }
        lastInspectedPID = pid
        if runSample {
            model.loadDeepDetails(for: pid, preserveSampleOutput: true)
            model.runCallStackSample(for: pid)
        } else {
            model.loadDeepDetails(for: pid)
        }
    }

    private func toggleInspector() {
        if showingInspector {
            withAnimation(.easeInOut(duration: 0.16)) {
                showingInspector = false
            }
            lastInspectedPID = nil
            return
        }
        guard let pid = selectedProcessID ?? model.filteredProcesses.first?.id else { return }
        openInspector(for: pid)
    }

    // MARK: - Top Tab & Action Bar

    private var tabAndActionBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ZtatTaskManagerTab.allCases) { tab in
                        let selected = activeTab == tab
                        Button {
                            activeTab = tab
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: tab.symbol)
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text(tab.title)
                                    .font(.system(size: 11.5, weight: selected ? .bold : .medium))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
                            .foregroundStyle(selected ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .help("⌘\(tab.rawValue + 1)")
                    }
                }
            }

            Spacer(minLength: 6)

            // Update Frequency Menu
            Menu {
                Button(ZtatL10n.tr("极速 (1 秒)", "Fast (1s)")) { model.isSamplingPaused = false; model.updateIntervalSeconds = 1.0 }
                Button(ZtatL10n.tr("标准 (2 秒)", "Normal (2s)")) { model.isSamplingPaused = false; model.updateIntervalSeconds = 2.0 }
                Button(ZtatL10n.tr("低功耗 (5 秒)", "Low Power (5s)")) { model.isSamplingPaused = false; model.updateIntervalSeconds = 5.0 }
                Divider()
                Button(model.isSamplingPaused ? ZtatL10n.tr("恢复自动刷新", "Resume Updates") : ZtatL10n.tr("暂停自动刷新", "Pause Updates")) {
                    model.isSamplingPaused.toggle()
                }
                Button(ZtatL10n.tr("立即刷新 (⌘R)", "Refresh Now (⌘R)")) {
                    model.refresh(forceSlowScans: true)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: model.isSamplingPaused ? "pause.circle.fill" : "timer")
                        .font(.system(size: 10.5))
                        .foregroundStyle(model.isSamplingPaused ? .orange : .secondary)
                    Text(model.isSamplingPaused ? ZtatL10n.tr("已暂停", "Paused") : "\(Int(model.updateIntervalSeconds))s")
                        .font(.system(size: 10.5, design: .monospaced))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                model.exportProcessesCSV()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(ZtatL10n.tr("导出进程快照为 CSV", "Export Process Snapshot CSV"))

            if isEmbeddedInSettings, let onOpenStandaloneWindow {
                Button {
                    onOpenStandaloneWindow()
                } label: {
                    Label(ZtatL10n.tr("独立窗口", "Pop Out"), systemImage: "macwindow.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(ZtatL10n.tr("以独立任务管理器窗口打开（全局快捷键 \(shortcutDisplayHint)）", "Open Standalone Window (\(shortcutDisplayHint))"))
            }
        }
    }

    // MARK: - Tab Content Switcher

    @ViewBuilder
    private var mainTabBody: some View {
        switch activeTab {
        case .cpu, .memory, .energy, .disk:
            processWorkspaceView
        case .network:
            networkAndPortsTabView
        case .gpu:
            gpuAndANETabView
        case .dev:
            devAgentsContainersTabView
        case .hardware:
            hardwareOverviewTabView
        }
    }

    // MARK: - Process Workspace (CPU / Memory / Energy / Disk Tabs)

    private var processWorkspaceView: some View {
        VStack(spacing: 0) {
            processControlsBar
                .padding(.horizontal, 14)
                .padding(.vertical, 7)

            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    processColumnHeader
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.03))
                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 1) {
                            if model.processViewMode == 0 {
                                ForEach(model.filteredAppGroups) { group in
                                    appGroupSectionView(group)
                                }
                            } else if model.processViewMode == 2 {
                                ForEach(model.filteredHierarchyRows) { row in
                                    processRowView(row.process, indentLevel: row.depth, childCount: row.childCount)
                                }
                            } else {
                                ForEach(model.filteredProcesses) { proc in
                                    processRowView(proc, indentLevel: 0, childCount: 0)
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showingInspector, let item = selectedProcessItem {
                    Divider()
                    processInspectorDrawer(item)
                        .frame(width: 310)
                }
            }

            Divider()
            selectedProcessActionBar
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.02))
        }
    }

    private var processControlsBar: some View {
        HStack(spacing: 10) {
            // Search box
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(ZtatL10n.tr("搜索进程、PID、用户、端口或目录…", "Filter name, PID, user, port, path…"), text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !model.searchQuery.isEmpty {
                    Button { model.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            .frame(minWidth: 200, maxWidth: 280)

            // View Mode: Grouped / Flat / Hierarchy Tree
            Picker("", selection: $model.processViewMode) {
                Text(ZtatL10n.tr("应用分组", "Grouped")).tag(0)
                Text(ZtatL10n.tr("平铺列表", "Flat")).tag(1)
                Text(ZtatL10n.tr("进程树", "Hierarchy")).tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)

            // Activity Monitor Scope Filter
            Picker(ZtatL10n.tr("范围", "Scope"), selection: $model.processScope) {
                Text(ZtatL10n.tr("全部进程", "All Processes")).tag(0)
                Text(ZtatL10n.tr("我的进程", "My Processes")).tag(1)
                Text(ZtatL10n.tr("窗口应用", "Windowed Apps")).tag(2)
                Text(ZtatL10n.tr("系统/守护", "System & Daemons")).tag(3)
                Text(ZtatL10n.tr("活跃 CPU", "Active CPU")).tag(4)
                Text(ZtatL10n.tr("开发与端口", "Dev & Ports")).tag(5)
                Text(ZtatL10n.tr("AI 智能体", "AI Agents")).tag(6)
            }
            .labelsHidden()
            .frame(width: 120)

            Spacer()

            Button {
                toggleInspector()
            } label: {
                Label(ZtatL10n.tr("检查器", "Inspect"), systemImage: "info.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedProcessID == nil && model.filteredProcesses.isEmpty)
            .help("⌘I")
        }
    }

    // MARK: - Dynamic Column Header (Adapts to CPU / Memory / Energy / Disk Tabs)

    private var processColumnHeader: some View {
        HStack(spacing: 8) {
            sortableColHeader(ZtatL10n.tr("进程 / 应用名称", "Process / Application"), col: 6, alignment: .leading)
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

            switch activeTab {
            case .memory:
                sortableColHeader(ZtatL10n.tr("内存占用", "Footprint"), col: 1, alignment: .trailing).frame(width: 82, alignment: .trailing)
                Text("RSS").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).frame(width: 68, alignment: .trailing)
                Text(ZtatL10n.tr("虚拟内存", "Virtual")).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                sortableColHeader("CPU %", col: 0, alignment: .trailing).frame(width: 60, alignment: .trailing)
                sortableColHeader("PID", col: 7, alignment: .trailing).frame(width: 54, alignment: .trailing)
                Text(ZtatL10n.tr("架构", "Kind")).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).frame(width: 52, alignment: .center)

            case .energy:
                sortableColHeader(ZtatL10n.tr("能耗影响", "Energy"), col: 2, alignment: .trailing).frame(width: 74, alignment: .trailing)
                Text(ZtatL10n.tr("空闲唤醒", "Wakeups")).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).frame(width: 78, alignment: .trailing)
                sortableColHeader("CPU %", col: 0, alignment: .trailing).frame(width: 64, alignment: .trailing)
                Text(ZtatL10n.tr("防休眠", "No Sleep")).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).frame(width: 58, alignment: .center)
                sortableColHeader("PID", col: 7, alignment: .trailing).frame(width: 54, alignment: .trailing)
                Text(ZtatL10n.tr("用户", "User")).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)

            case .disk:
                sortableColHeader(ZtatL10n.tr("写入字节", "Bytes Written"), col: 3, alignment: .trailing).frame(width: 82, alignment: .trailing)
                sortableColHeader(ZtatL10n.tr("读取字节", "Bytes Read"), col: 4, alignment: .trailing).frame(width: 82, alignment: .trailing)
                Text(ZtatL10n.tr("写入速率", "Write/s")).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                Text(ZtatL10n.tr("读取速率", "Read/s")).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                sortableColHeader("PID", col: 7, alignment: .trailing).frame(width: 54, alignment: .trailing)

            default: // CPU
                sortableColHeader("CPU %", col: 0, alignment: .trailing).frame(width: 66, alignment: .trailing)
                sortableColHeader(ZtatL10n.tr("CPU 时间", "CPU Time"), col: 8, alignment: .trailing).frame(width: 68, alignment: .trailing)
                sortableColHeader(ZtatL10n.tr("线程", "Threads"), col: 5, alignment: .trailing).frame(width: 48, alignment: .trailing)
                sortableColHeader(ZtatL10n.tr("内存", "Memory"), col: 1, alignment: .trailing).frame(width: 74, alignment: .trailing)
                sortableColHeader("PID", col: 7, alignment: .trailing).frame(width: 54, alignment: .trailing)
                Text(ZtatL10n.tr("用户", "User")).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                Text(ZtatL10n.tr("架构", "Kind")).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).frame(width: 50, alignment: .center)
            }
        }
    }

    private func sortableColHeader(_ title: String, col: Int, alignment: Alignment) -> some View {
        Button {
            if model.sortColumn == col {
                model.sortAscending.toggle()
            } else {
                model.sortColumn = col
                model.sortAscending = (col == 6)
            }
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(model.sortColumn == col ? Color.accentColor : .secondary)
                if model.sortColumn == col {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - App Group Row + Child Rows

    private func appGroupSectionView(_ group: VitalsAppGroup) -> some View {
        let isExpanded = model.expandedGroupIDs.contains(group.id)
        let primary = group.primaryProcess
        let isSelected = primary != nil && selectedProcessID == primary?.id

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    model.toggleGroupExpanded(group.id)
                } label: {
                    Image(systemName: group.processCount > 1 ? (isExpanded ? "chevron.down" : "chevron.right") : "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .opacity(group.processCount > 1 ? 1 : 0)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                VitalsFormat.appIcon(for: group.bundleURL)
                    .resizable().scaledToFit().frame(width: 16, height: 16)

                HStack(spacing: 5) {
                    Text(group.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    if group.processCount > 1 {
                        Text("\(group.processCount)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .foregroundStyle(.secondary)
                    }
                    if let firstPort = group.ports.first {
                        Text(group.ports.count > 1 ? ":\(firstPort)+\(group.ports.count - 1)" : ":\(firstPort)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.14)))
                            .foregroundStyle(.blue)
                    }
                }
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

                groupMetricColumns(group)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if group.processCount > 1 {
                    model.toggleGroupExpanded(group.id)
                } else if let p = primary {
                    openInspector(for: p.id)
                }
            }
            .onTapGesture {
                if let p = primary {
                    selectedProcessID = p.id
                }
            }
            .contextMenu {
                if let p = primary {
                    Button(ZtatL10n.tr("打开进程检查器 (⌘I)", "Inspect Process (⌘I)")) {
                        openInspector(for: p.id, tab: .overview)
                    }
                    Button(ZtatL10n.tr("在访达中显示", "Reveal in Finder")) { model.revealInFinder(p) }
                    Divider()
                }
                Button(ZtatL10n.tr("优雅退出应用组", "Quit App Group")) { model.terminateAppGroup(group, force: false) }
                Button(ZtatL10n.tr("强制退出应用组…", "Force Quit App Group…"), role: .destructive) { confirmKillTarget = .group(group) }
            }

            if isExpanded && group.processCount > 1 {
                ForEach(group.processes) { child in
                    processRowView(child, indentLevel: 1, childCount: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func groupMetricColumns(_ group: VitalsAppGroup) -> some View {
        let p = group.primaryProcess
        switch activeTab {
        case .memory:
            Text(VitalsFormat.memoryMB(group.totalMemoryMB))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.green)
                .frame(width: 82, alignment: .trailing)
            Text(VitalsFormat.memoryMB(group.totalRSSMB))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)
            Text(VitalsFormat.memoryMB(group.processes.reduce(0) { $0 + $1.virtualMemoryMB }))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .trailing)
            Text(String(format: "%.1f%%", group.totalCPU))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.blue)
                .frame(width: 60, alignment: .trailing)
            Text(p.map { "\($0.id)" } ?? "—")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
            archBadge(p?.architecture ?? "Apple").frame(width: 52)

        case .energy:
            Text(String(format: "%.1f", group.totalEnergyImpact))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(group.totalEnergyImpact > 20 ? .orange : .primary)
                .frame(width: 74, alignment: .trailing)
            Text(String(format: "%.1f/s", group.totalIdleWakeupsPerSec))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            Text(String(format: "%.1f%%", group.totalCPU))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.blue)
                .frame(width: 64, alignment: .trailing)
            Text(group.preventingSleep ? ZtatL10n.tr("是", "Yes") : "—")
                .font(.system(size: 10, weight: group.preventingSleep ? .bold : .regular))
                .foregroundStyle(group.preventingSleep ? Color.orange : Color.secondary.opacity(0.45))
                .frame(width: 58)
            Text(p.map { "\($0.id)" } ?? "—")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
            Text(p?.user ?? "—")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 66, alignment: .leading)

        case .disk:
            Text(VitalsFormat.bytes(group.totalDiskWriteBytes))
                .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.pink)
                .frame(width: 82, alignment: .trailing)
            Text(VitalsFormat.bytes(group.totalDiskReadBytes))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.purple)
                .frame(width: 82, alignment: .trailing)
            Text(VitalsFormat.rateBps(group.totalDiskWriteRateBps))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
            Text(VitalsFormat.rateBps(group.totalDiskReadRateBps))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
            Text(p.map { "\($0.id)" } ?? "—")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)

        default:
            Text(String(format: "%.1f%%", group.totalCPU))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(group.totalCPU > 80 ? .orange : .blue)
                .frame(width: 66, alignment: .trailing)
            Text(VitalsFormat.cpuTime(group.processes.reduce(0) { $0 + $1.cpuTimeSeconds }))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)
            Text("\(group.totalThreads)")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            Text(VitalsFormat.memoryMB(group.totalMemoryMB))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.primary)
                .frame(width: 74, alignment: .trailing)
            Text(p.map { "\($0.id)" } ?? "—")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
            Text(p?.user ?? "—")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 64, alignment: .leading)
            archBadge(p?.architecture ?? "Apple").frame(width: 50)
        }
    }

    // MARK: - Individual Process Row (Flat / Child / Tree Hierarchy)

    private func processRowView(_ proc: VitalsProcessItem, indentLevel: Int, childCount: Int) -> some View {
        let isSelected = selectedProcessID == proc.id
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                if indentLevel > 0 {
                    Spacer().frame(width: CGFloat(indentLevel) * 16)
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                VitalsFormat.appIcon(for: proc.bundleURL)
                    .resizable().scaledToFit().frame(width: 14, height: 14)
                Text(proc.name)
                    .font(.system(size: 11, weight: indentLevel == 0 ? .medium : .regular))
                    .foregroundStyle(proc.isPaused ? .orange : .primary)
                    .lineLimit(1)
                if proc.isPaused {
                    Text(ZtatL10n.tr("暂停", "STOP"))
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
                if childCount > 0 {
                    Text("↳\(childCount)")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let port = proc.ports.first {
                    Text(":\(port)")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.blue.opacity(0.14)))
                        .foregroundStyle(.blue)
                }
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

            switch activeTab {
            case .memory:
                Text(VitalsFormat.memoryMB(proc.memoryMB))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(.green)
                    .frame(width: 82, alignment: .trailing)
                Text(VitalsFormat.memoryMB(proc.rssMB))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .trailing)
                Text(VitalsFormat.memoryMB(proc.virtualMemoryMB))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .frame(width: 72, alignment: .trailing)
                Text(String(format: "%.1f%%", proc.cpuPercent))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.blue)
                    .frame(width: 60, alignment: .trailing)
                Text("\(proc.id)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
                archBadge(proc.architecture).frame(width: 52)

            case .energy:
                Text(String(format: "%.1f", proc.energyImpact))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(proc.energyImpact > 15 ? .orange : .primary)
                    .frame(width: 74, alignment: .trailing)
                Text(String(format: "%.1f/s", proc.idleWakeupsPerSec))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .trailing)
                Text(String(format: "%.1f%%", proc.cpuPercent))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.blue)
                    .frame(width: 64, alignment: .trailing)
                Text(proc.preventingSleep ? ZtatL10n.tr("是", "Yes") : "—")
                    .font(.system(size: 10, weight: proc.preventingSleep ? .bold : .regular))
                    .foregroundStyle(proc.preventingSleep ? Color.orange : Color.secondary.opacity(0.45))
                    .frame(width: 58)
                Text("\(proc.id)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
                Text(proc.user)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 66, alignment: .leading)

            case .disk:
                Text(VitalsFormat.bytes(proc.diskWriteBytes))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(.pink)
                    .frame(width: 82, alignment: .trailing)
                Text(VitalsFormat.bytes(proc.diskReadBytes))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.purple)
                    .frame(width: 82, alignment: .trailing)
                Text(VitalsFormat.rateBps(proc.diskWriteRateBps))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .trailing)
                Text(VitalsFormat.rateBps(proc.diskReadRateBps))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .trailing)
                Text("\(proc.id)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)

            default:
                Text(String(format: "%.1f%%", proc.cpuPercent))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(proc.cpuPercent > 50 ? .orange : .blue)
                    .frame(width: 66, alignment: .trailing)
                Text(VitalsFormat.cpuTime(proc.cpuTimeSeconds))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .trailing)
                Text("\(proc.threads)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                Text(VitalsFormat.memoryMB(proc.memoryMB))
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 74, alignment: .trailing)
                Text("\(proc.id)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
                Text(proc.user)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 64, alignment: .leading)
                archBadge(proc.architecture).frame(width: 50)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : (indentLevel > 0 ? Color.primary.opacity(0.015) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            openInspector(for: proc.id)
        }
        .onTapGesture {
            selectedProcessID = proc.id
        }
        .contextMenu {
            Button(ZtatL10n.tr("进程检查器 (⌘I)", "Inspect Process (⌘I)")) {
                openInspector(for: proc.id, tab: .overview)
            }
            Button(ZtatL10n.tr("采样实时调用栈…", "Sample Process…")) {
                openInspector(for: proc.id, tab: .sample, runSample: true)
            }
            Button(ZtatL10n.tr("在访达中显示", "Reveal in Finder")) { model.revealInFinder(proc) }
            Button(ZtatL10n.tr("拷贝 PID", "Copy PID")) { model.copyText("\(proc.id)") }
            Button(ZtatL10n.tr("拷贝路径", "Copy Path")) { model.copyText(proc.path) }
            Divider()
            Button(proc.isPaused ? ZtatL10n.tr("恢复运行 (SIGCONT)", "Resume (SIGCONT)") : ZtatL10n.tr("暂停挂起 (SIGSTOP)", "Pause (SIGSTOP)")) {
                model.togglePauseProcess(proc)
            }
            Menu(ZtatL10n.tr("发送 Unix 信号", "Send Unix Signal")) {
                ForEach(VitalsUnixSignal.allCases) { sig in
                    Button(sig.label) { model.sendSignal(sig, to: proc) }
                }
            }
            Divider()
            Button(ZtatL10n.tr("优雅退出 (SIGTERM)", "Quit (SIGTERM)")) { model.terminateProcess(proc, force: false) }
            Button(ZtatL10n.tr("强制终止 (SIGKILL)…", "Force Quit (SIGKILL)…"), role: .destructive) { confirmKillTarget = .process(proc) }
        }
    }

    private func archBadge(_ arch: String) -> some View {
        let isApple = arch.lowercased().contains("apple")
        return Text(isApple ? "Apple" : "Intel")
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill((isApple ? Color.blue : Color.orange).opacity(0.14)))
            .foregroundStyle(isApple ? .blue : .orange)
    }

    // MARK: - Tabbed Deep Process Inspector Drawer (Activity Monitor ⌘I + Vitals ProcessInspector)

    private func processInspectorDrawer(_ item: VitalsProcessItem) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                VitalsFormat.appIcon(for: item.bundleURL)
                    .resizable().scaledToFit().frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 12.5, weight: .bold)).lineLimit(1)
                    Text("PID \(item.id) · PPID \(item.ppid) · \(item.user) · \(item.architecture)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showingInspector = false }
                    lastInspectedPID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(10)

            Picker("", selection: $inspectorTab) {
                ForEach(InspectorSubTab.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch inspectorTab {
                    case .overview:
                        inspectorOverviewTab(item)
                    case .argsEnv:
                        inspectorArgsEnvTab()
                    case .openFiles:
                        inspectorOpenFilesTab()
                    case .signature:
                        inspectorSignatureTab(item)
                    case .sample:
                        inspectorSampleTab(item)
                    }
                }
                .padding(11)
            }
        }
        .background(Color.primary.opacity(0.025))
    }

    private func inspectorOverviewTab(_ item: VitalsProcessItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 5) {
                kvRow(ZtatL10n.tr("状态", "State"), item.stateLabel)
                kvRow(ZtatL10n.tr("CPU 使用率", "% CPU"), String(format: "%.1f%% (整机 %.1f%%)", item.cpuPercent, item.cpuPercent / Double(max(1, ProcessInfo.processInfo.processorCount))))
                kvRow(ZtatL10n.tr("累计 CPU 时间", "CPU Time"), VitalsFormat.cpuTime(item.cpuTimeSeconds))
                kvRow(ZtatL10n.tr("物理内存 (Footprint)", "Footprint"), VitalsFormat.memoryMB(item.memoryMB))
                kvRow(ZtatL10n.tr("常驻内存 (RSS)", "Resident (RSS)"), VitalsFormat.memoryMB(item.rssMB))
                kvRow(ZtatL10n.tr("虚拟内存", "Virtual Size"), VitalsFormat.memoryMB(item.virtualMemoryMB))
                kvRow(ZtatL10n.tr("线程数", "Threads"), "\(item.threads)")
                kvRow(ZtatL10n.tr("空闲唤醒", "Idle Wakeups"), "\(item.idleWakeups) (\(String(format: "%.1f/s", item.idleWakeupsPerSec)))")
                kvRow(ZtatL10n.tr("磁盘读 / 写", "Disk R / W"), "\(VitalsFormat.bytes(item.diskReadBytes)) / \(VitalsFormat.bytes(item.diskWriteBytes))")
                kvRow(ZtatL10n.tr("能耗影响", "Energy Impact"), String(format: "%.1f", item.energyImpact))
                if let st = item.startTime {
                    kvRow(ZtatL10n.tr("启动时间", "Started"), st.formatted(date: .abbreviated, time: .shortened))
                }
                if let parentName = model.deepDetails?.parentName {
                    HStack {
                        Text(ZtatL10n.tr("父进程", "Parent")).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Button("\(parentName) (\(item.ppid))") {
                            selectedProcessID = item.ppid
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10, design: .monospaced))
                    }
                }
            }

            if let kids = model.deepDetails?.children, !kids.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(ZtatL10n.tr("子进程 (\(kids.count))", "Child Processes (\(kids.count))"))
                        .font(.system(size: 10.5, weight: .bold))
                    ForEach(kids.prefix(8), id: \.pid) { kid in
                        Button("\(kid.name) (PID \(kid.pid))") {
                            selectedProcessID = kid.pid
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10, design: .monospaced))
                    }
                }
            }

            if !item.ports.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(ZtatL10n.tr("监听端口", "Listening Ports")).font(.system(size: 10.5, weight: .bold))
                    ForEach(item.ports, id: \.self) { port in
                        HStack {
                            Text(":\(port)").font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(.blue)
                            Spacer()
                            Button(ZtatL10n.tr("浏览器打开", "Open")) { model.openLocalPort(port) }
                                .buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text(ZtatL10n.tr("可执行文件路径", "Executable Path")).font(.system(size: 10.5, weight: .bold))
                Text(item.path)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let cwd = model.deepDetails?.workingDir ?? item.workingDir {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ZtatL10n.tr("工作目录 (CWD)", "Working Directory")).font(.system(size: 10.5, weight: .bold))
                    Text(cwd)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func inspectorArgsEnvTab() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isLoadingDeepDetails {
                HStack { ProgressView().controlSize(.small); Text(ZtatL10n.tr("读取命令行与环境变量…", "Loading args & env…")).font(.caption) }
            } else if let d = model.deepDetails {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(ZtatL10n.tr("完整命令行参数", "Command Line")).font(.system(size: 10.5, weight: .bold))
                        Spacer()
                        Button(ZtatL10n.tr("拷贝", "Copy")) { model.copyText(d.commandLine) }
                            .buttonStyle(.bordered).controlSize(.mini)
                    }
                    Text(d.commandLine.isEmpty ? "—" : d.commandLine)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                }

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(ZtatL10n.tr("环境变量 (\(d.environment.count))", "Environment Variables (\(d.environment.count))"))
                        .font(.system(size: 10.5, weight: .bold))
                    if d.environment.isEmpty {
                        Text(ZtatL10n.tr("无可读环境变量（或受系统权限保护）。", "No readable environment variables (protected process)."))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(d.environment.prefix(60).enumerated()), id: \.offset) { _, pair in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pair.key).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(.blue)
                                Text(pair.value).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    private func inspectorOpenFilesTab() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isLoadingDeepDetails {
                HStack { ProgressView().controlSize(.small); Text(ZtatL10n.tr("正在通过 lsof 读取打开的文件与套接字…", "Reading open files & sockets…")).font(.caption) }
            } else if let d = model.deepDetails {
                TextField(ZtatL10n.tr("筛选路径或套接字…", "Filter files / sockets…"), text: $fileFilterQuery)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                let q = fileFilterQuery.lowercased()
                let sockets = d.networkSockets.filter { q.isEmpty || $0.name.lowercased().contains(q) }
                let files = d.openFiles.filter { q.isEmpty || $0.name.lowercased().contains(q) }

                Text(ZtatL10n.tr("网络与 Unix 套接字 (\(sockets.count))", "Sockets (\(sockets.count))"))
                    .font(.system(size: 10.5, weight: .bold))
                if sockets.isEmpty {
                    Text("—").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(sockets.prefix(40)) { s in
                        Text("[\(s.type)] \(s.name)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.blue)
                            .textSelection(.enabled)
                    }
                }

                Divider()
                Text(ZtatL10n.tr("打开的文件与库 (\(files.count))", "Open Files (\(files.count))"))
                    .font(.system(size: 10.5, weight: .bold))
                ForEach(files.prefix(80)) { f in
                    Text("[\(f.fd)/\(f.type)] \(f.name)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func inspectorSignatureTab(_ item: VitalsProcessItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isLoadingDeepDetails {
                ProgressView().controlSize(.small)
            } else if let d = model.deepDetails {
                kvRow(ZtatL10n.tr("签名标识符", "Signing ID"), d.signingIdentifier ?? "—")
                kvRow("Team ID", d.teamIdentifier ?? "—")
                kvRow(ZtatL10n.tr("签发证书", "Authority"), d.authority ?? "—")
                kvRow("Bundle ID", item.bundleIdentifier ?? "—")
                kvRow("Hardened Runtime", d.isHardenedRuntime ? ZtatL10n.tr("已开启", "Enabled") : ZtatL10n.tr("未开启", "Off"))
                kvRow("App Sandbox", d.isSandboxed ? ZtatL10n.tr("沙盒隔离", "Sandboxed") : ZtatL10n.tr("非沙盒", "Unsandboxed"))
            }
        }
    }

    private func inspectorSampleTab(_ item: VitalsProcessItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    model.runCallStackSample(for: item.id)
                } label: {
                    Label(ZtatL10n.tr("采集实时调用栈 (1秒)", "Sample Call Stack (1s)"), systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isSamplingCallStack)

                if !model.sampleOutput.isEmpty {
                    Button(ZtatL10n.tr("拷贝", "Copy")) {
                        model.copyText(model.sampleOutput)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if model.isSamplingCallStack {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(ZtatL10n.tr("正在运行 /usr/bin/sample…", "Running /usr/bin/sample…")).font(.caption)
                }
            }

            if !model.sampleOutput.isEmpty {
                Text(model.sampleOutput)
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            } else {
                Text(ZtatL10n.tr("点击上方按钮即可像原生「活动监视器 → 采样进程」一样捕获当前线程堆栈，用于排查卡死或高 CPU 热点。",
                                "Capture live thread call stacks just like Activity Monitor's Sample Process to diagnose hangs or CPU spikes."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func kvRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 10, weight: .medium, design: .monospaced)).lineLimit(1).textSelection(.enabled)
        }
    }

    // MARK: - Selected Process Action Bar

    private var selectedProcessActionBar: some View {
        HStack(spacing: 8) {
            if let item = selectedProcessItem {
                Text("\(item.name) (PID \(item.id))")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer()

                Button {
                    openInspector(for: item.id, tab: .sample, runSample: true)
                } label: {
                    Label(ZtatL10n.tr("采样", "Sample"), systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered).controlSize(.small)

                Button {
                    model.togglePauseProcess(item)
                } label: {
                    Label(item.isPaused ? ZtatL10n.tr("恢复", "Resume") : ZtatL10n.tr("暂停", "Pause"),
                          systemImage: item.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered).controlSize(.small)

                Menu {
                    ForEach(VitalsUnixSignal.allCases) { sig in
                        Button(sig.label) { model.sendSignal(sig, to: item) }
                    }
                } label: {
                    Label(ZtatL10n.tr("信号", "Signal"), systemImage: "bolt.horizontal")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button { model.revealInFinder(item) } label: {
                    Label(ZtatL10n.tr("访达", "Finder"), systemImage: "folder")
                }
                .buttonStyle(.bordered).controlSize(.small)

                Button { model.terminateProcess(item, force: false) } label: {
                    Label(ZtatL10n.tr("退出", "Quit"), systemImage: "xmark")
                }
                .buttonStyle(.bordered).controlSize(.small)

                Button { confirmKillTarget = .process(item) } label: {
                    Label(ZtatL10n.tr("强制退出", "Force Quit"), systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
            } else {
                Text(ZtatL10n.tr("单击选中进程，双击或按 ⌘I 打开深度检查器（命令行/文件/端口/签名/采样）。全局快捷键：\(shortcutDisplayHint)",
                                "Click a process to act, double-click or press ⌘I to inspect (Args/Files/Signature/Sample). Global hotkey: \(shortcutDisplayHint)"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
    }

    // MARK: - Dedicated Tabs: Network / GPU / Dev / Hardware

    private var networkAndPortsTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VitalsNetworkPaneView(model: model, onSelectPane: nil)
                VitalsPortsPaneView(model: model)
            }
            .padding(14)
        }
    }

    private var gpuAndANETabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VitalsGPUPaneView(model: model, onSelectPane: nil).frame(maxWidth: .infinity)
                    if hw.aneSupported {
                        VitalsANEPaneView(model: model).frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(14)
        }
    }

    private var devAgentsContainersTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VitalsAgentsPaneView(model: model).frame(maxWidth: .infinity)
                    VitalsContainersPaneView(model: model).frame(maxWidth: .infinity)
                }

                // Active Dev Projects detected by CWD + Ports
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "folder.badge.gearshape").foregroundStyle(.blue)
                        Text(ZtatL10n.tr("活跃开发项目目录 (\(model.devProjects.count))", "Active Developer Projects (\(model.devProjects.count))"))
                            .font(.system(size: 12.5, weight: .bold))
                        Spacer()
                    }
                    if model.devProjects.isEmpty {
                        Text(ZtatL10n.tr("未检测到带活跃开发进程的项目目录。", "No active developer project folders detected."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.devProjects) { proj in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(proj.name).font(.system(size: 12, weight: .bold))
                                    Text(proj.path).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                ForEach(proj.ports.prefix(3), id: \.self) { port in
                                    Button(":\(port)") { model.openLocalPort(port) }
                                        .buttonStyle(.bordered).controlSize(.mini)
                                }
                                Text("\(proj.pids.count) \(ZtatL10n.tr("进程", "procs")) · \(VitalsFormat.memoryMB(proj.totalMemoryMB))")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Button { model.revealPathInFinder(proj.path) } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.bordered).controlSize(.mini)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }
            .padding(14)
        }
    }

    private var hardwareOverviewTabView: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(VitalsPane.allCases.filter { $0 != .ane || hw.aneSupported }) { pane in
                        let sel = hardwareSubPane == pane
                        Button {
                            hardwareSubPane = pane
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: pane.symbol).font(.system(size: 10))
                                Text(pane.title).font(.system(size: 11, weight: sel ? .bold : .medium))
                            }
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(sel ? Color.accentColor : Color.primary.opacity(0.06)))
                            .foregroundStyle(sel ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            Divider()
            ScrollView {
                VitalsPaneContentRouter(
                    model: model,
                    pane: hardwareSubPane,
                    isCompactPopover: false,
                    onSelectPane: { pane in
                        withAnimation(.easeInOut(duration: 0.16)) {
                            hardwareSubPane = pane
                        }
                    }
                )
                .padding(14)
            }
        }
    }

    // MARK: - Activity Monitor Live Bottom Summary Strip

    private var bottomTelemetryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                switch activeTab {
                case .memory:
                    VitalsSparkline(values: model.memHistory, color: hw.memory.level == .critical ? .red : (hw.memory.level == .warning ? .orange : .green), fixedMax: 1.0)
                        .frame(width: 110, height: 34)
                    metricPair(ZtatL10n.tr("物理内存", "Physical"), String(format: "%.0f GB", hw.memory.totalGB))
                    metricPair(ZtatL10n.tr("已使用", "Used"), String(format: "%.2f GB", hw.memory.usedGB), color: .green)
                    metricPair(ZtatL10n.tr("App / 联动 / 压缩", "App/Wired/Comp"), String(format: "%.1f / %.1f / %.1f G", hw.memory.appGB, hw.memory.wiredGB, hw.memory.compressedGB))
                    metricPair(ZtatL10n.tr("已缓存", "Cached"), String(format: "%.1f GB", hw.memory.cachedGB))
                    metricPair("Swap", String(format: "%.2f GB", hw.memory.swapUsedGB), color: hw.memory.swapUsedGB > 2 ? .orange : .primary)
                    metricPair(ZtatL10n.tr("压力", "Pressure"), hw.memory.level.label, color: hw.memory.level == .normal ? .green : .orange)

                case .energy:
                    VitalsSparkline(values: model.powerHistory, color: .orange)
                        .frame(width: 110, height: 34)
                    metricPair(ZtatL10n.tr("电量", "Battery"), hw.batteryPercent.map { "\($0)%" } ?? "AC", color: hw.batteryCharging ? .green : .orange)
                    metricPair(ZtatL10n.tr("整机功耗", "System Power"), hw.powerRails.systemTotalWatts.map { String(format: "%.1f W", $0) } ?? String(format: "%.1f W", hw.powerRails.packageTotalWatts), color: .orange)
                    metricPair(ZtatL10n.tr("CPU / GPU / ANE", "CPU/GPU/ANE"), String(format: "%.1f / %.1f / %.1f W", hw.powerRails.cpuWatts, hw.powerRails.gpuWatts, hw.powerRails.aneWatts))
                    metricPair(ZtatL10n.tr("防休眠断言", "Sleep Assertions"), "\(model.sleepAssertions.count)")

                case .disk:
                    VitalsSparkline(values: model.diskReadHistory, color: .purple, secondaryValues: model.diskWriteHistory, secondaryColor: .pink)
                        .frame(width: 110, height: 34)
                    metricPair(ZtatL10n.tr("实时读取", "Read/s"), String(format: "%.1f MB/s", hw.diskReadMBs), color: .purple)
                    metricPair(ZtatL10n.tr("实时写入", "Write/s"), String(format: "%.1f MB/s", hw.diskWriteMBs), color: .pink)
                    metricPair("IOPS (R/W)", String(format: "%.0f / %.0f", hw.diskReadIOPS, hw.diskWriteIOPS))
                    metricPair(ZtatL10n.tr("累计读 / 写", "Total R/W"), String(format: "%.1f / %.1f GB", hw.diskTotalReadGB, hw.diskTotalWrittenGB))

                case .network:
                    VitalsSparkline(values: model.netDownHistory, color: .teal, secondaryValues: model.netUpHistory, secondaryColor: .cyan)
                        .frame(width: 110, height: 34)
                    metricPair(ZtatL10n.tr("下载", "Download"), VitalsFormat.speedKBs(hw.netDownloadKBs), color: .teal)
                    metricPair(ZtatL10n.tr("上传", "Upload"), VitalsFormat.speedKBs(hw.netUploadKBs), color: .cyan)
                    metricPair(ZtatL10n.tr("接口 / IP", "Interface"), "\(hw.activeInterfaceName) · \(hw.localIPv4)")
                    metricPair(ZtatL10n.tr("监听端口", "Ports"), "\(model.listeningPorts.count)")

                default: // CPU / GPU / Dev / Hardware
                    VitalsSparkline(values: model.cpuHistory, color: .blue, fixedMax: 1.0)
                        .frame(width: 110, height: 34)
                    metricPair(ZtatL10n.tr("系统 / 用户 / 空闲", "Sys / Usr / Idle"),
                               String(format: "%.1f%% / %.1f%% / %.1f%%", hw.cpuSystem * 100, hw.cpuUser * 100, hw.cpuIdle * 100), color: .blue)
                    metricPair("GPU", String(format: "%.0f%%", hw.gpuUsage * 100), color: .indigo)
                    metricPair(ZtatL10n.tr("负载均值", "Load Avg"), String(format: "%.2f  %.2f  %.2f", hw.loadAverages[0], hw.loadAverages[1], hw.loadAverages[2]))
                    metricPair(ZtatL10n.tr("进程 / 线程", "Procs / Threads"), "\(model.processes.count) / \(model.totalThreadCount)")
                    if let temp = hw.hottestTempC {
                        metricPair(ZtatL10n.tr("峰值温度", "Peak Temp"), String(format: "%.0f°C", temp), color: temp > 80 ? .red : .orange)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func metricPair(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundStyle(color).lineLimit(1)
        }
    }
}
