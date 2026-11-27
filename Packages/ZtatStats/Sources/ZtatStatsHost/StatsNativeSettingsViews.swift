// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Pure native macOS SwiftUI Form(.grouped) views replacing legacy AppKit
// Dashboard and ApplicationSettings inside ztat's unified Settings window.

import AppKit
import StatsKit
import SwiftUI
import UniformTypeIdentifiers
import ZtatCore

/// Pure native macOS SwiftUI Hardware Dashboard (`性能监控 → 设备概览`).
@MainActor
public struct StatsNativeDashboardView: View {
    @ObservedObject private var l10n = ZtatLocalizationStore.shared
    @State private var infoRevision: Int = 0

    public init() {}

    public var body: some View {
        let _ = (l10n.revision, infoRevision)
        let device = SystemKit.shared.device

        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: device.model.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.model.name)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        Text(osSummary(device))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let bootDate = device.bootDate {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                Text(ZtatL10n.tr("运行时间：", "Uptime: ") + formatUptime(from: bootDate, to: context.date))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section(ZtatL10n.tr("硬件规格", "Hardware Specifications")) {
                specRow(ZtatL10n.tr("处理器", "Processor"), value: processorSummary(device))
                specRow(ZtatL10n.tr("内存", "Memory"), value: memorySummary(device))
                specRow(ZtatL10n.tr("图形", "Graphics"), value: graphicsSummary(device))
                specRow(ZtatL10n.tr("磁盘", "Disks"), value: disksSummary(device))
                specRow(ZtatL10n.tr("显示器", "Displays"), value: displaysSummary(device))
            }

            Section(ZtatL10n.tr("设备标识", "Device Identity")) {
                LabeledContent(ZtatL10n.tr("机型标识符", "Model Identifier")) {
                    Text(device.model.id)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent(ZtatL10n.tr("出厂年份", "Production Year")) {
                    Text("\(device.model.year)")
                        .monospacedDigit()
                }
                LabeledContent(ZtatL10n.tr("序列号", "Serial Number")) {
                    Text(device.serialNumber ?? ZtatL10n.tr("未知", "Unknown"))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            infoRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .statsSystemInfoUpdated)) { _ in
            infoRevision &+= 1
        }
    }

    private func specRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func osSummary(_ device: device_s) -> String {
        let name = device.os?.name ?? ZtatL10n.tr("未知", "Unknown")
        let version = device.os?.version.getFullVersion() ?? ""
        let build: String
        if let rawBuild = device.os?.build, !rawBuild.isEmpty {
            build = " (\(rawBuild))"
        } else {
            build = ""
        }
        return "macOS \(name) \(version)\(build)"
    }

    private func processorSummary(_ device: device_s) -> String {
        guard let cpu = device.info.cpu, cpu.name != nil || cpu.physicalCores != nil else {
            return ZtatL10n.tr("未知", "Unknown")
        }
        var lines: [String] = []
        if let name = cpu.name { lines.append(name) }
        var coreParts: [String] = []
        if let cores = cpu.physicalCores {
            coreParts.append(ZtatL10n.tr("\(cores) 核心", "\(cores) cores"))
        }
        if let threads = cpu.logicalCores, threads != cpu.physicalCores {
            coreParts.append(ZtatL10n.tr("\(threads) 线程", "\(threads) threads"))
        }
        if !coreParts.isEmpty { lines.append(coreParts.joined(separator: " · ")) }
        var clusterParts: [String] = []
        if let p = cpu.pCores, p > 0 { clusterParts.append("\(p)P") }
        if let e = cpu.eCores, e > 0 { clusterParts.append("\(e)E") }
        if let s = cpu.sCores, s > 0 { clusterParts.append("\(s)S") }
        if !clusterParts.isEmpty { lines.append(clusterParts.joined(separator: " + ")) }
        return lines.joined(separator: "\n")
    }

    private func memorySummary(_ device: device_s) -> String {
        guard let dimms = device.info.ram?.dimms, !dimms.isEmpty else {
            return ZtatL10n.tr("加载中…", "Loading…")
        }
        return dimms.map { dimm in
            [dimm.size, dimm.speed, dimm.type].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private func graphicsSummary(_ device: device_s) -> String {
        guard let gpus = device.info.gpu, !gpus.isEmpty else {
            return ZtatL10n.tr("加载中…", "Loading…")
        }
        return gpus.map { gpu in
            var row = gpu.name ?? ZtatL10n.tr("未知", "Unknown")
            var meta: [String] = []
            if let cores = gpu.cores { meta.append(ZtatL10n.tr("\(cores) 核", "\(cores) cores")) }
            if let vram = gpu.vram { meta.append(vram) }
            if !meta.isEmpty { row += " (\(meta.joined(separator: ", ")))" }
            return row
        }.joined(separator: "\n")
    }

    private func disksSummary(_ device: device_s) -> String {
        guard let disks = device.info.disk, !disks.isEmpty else {
            return ZtatL10n.tr("加载中…", "Loading…")
        }
        return disks.map { disk in
            var row = disk.name ?? ZtatL10n.tr("未知", "Unknown")
            if let size = disk.size {
                row += " (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
            }
            return row
        }.joined(separator: "\n")
    }

    private func displaysSummary(_ device: device_s) -> String {
        guard let displays = device.display, !displays.isEmpty else {
            return ZtatL10n.tr("加载中…", "Loading…")
        }
        return displays.map { d in
            var row = d.name ?? ZtatL10n.tr("显示器", "Display")
            if let size = d.size {
                let formatted = String(format: "%.1f", size).replacingOccurrences(of: ".0", with: "")
                row += " (\(formatted)\")"
            }
            var details: [String] = []
            if let res = d.resolution { details.append("\(Int(res.width))×\(Int(res.height))") }
            if let rr = d.refreshRate { details.append("\(Int(rr.rounded()))Hz") }
            if !details.isEmpty { row += " · \(details.joined(separator: ", "))" }
            return row
        }.joined(separator: "\n")
    }

    private func formatUptime(from bootDate: Date, to now: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: bootDate, to: now) ?? ZtatL10n.tr("未知", "Unknown")
    }
}

/// Pure native macOS SwiftUI Global, Combined Bar, Backup & Stress Test settings (`性能监控 → 全局与压测`).
@MainActor
public struct StatsNativeGlobalSettingsView: View {
    @ObservedObject private var host: ZtatStatsHost
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    @State private var temperatureUnit: String = Store.shared.string(key: "temperature_units", defaultValue: "system")
    @State private var keepMenuBarPosition: Bool = Store.shared.bool(key: "keep_menubar_positions", defaultValue: false)
    @State private var combinedDisplay: String = CombinedModulesWidget.current.rawValue
    @State private var combinedSpacing: String = Store.shared.string(key: "CombinedModules_spacing", defaultValue: "none")
    @State private var combinedSeparator: Bool = Store.shared.bool(key: "CombinedModules_separator", defaultValue: false)
    @State private var orderedIDs: [String] = []
    @State private var showResetConfirmation: Bool = false

    @State private var eCoreTest = CPUStressTest(type: .efficiency)
    @State private var pCoreTest = CPUStressTest(type: .performance)
    @State private var sCoreTest = CPUStressTest(type: .super)
    @State private var gpuTest = GPUStressTest()
    @State private var eRunning = false
    @State private var pRunning = false
    @State private var sRunning = false
    @State private var gpuRunning = false

    @MainActor
    public init(host: ZtatStatsHost? = nil) {
        self.host = host ?? .shared
    }

    public var body: some View {
        let _ = l10n.revision
        Form {
            Section(ZtatL10n.tr("显示与布局", "Display & Layout")) {
                Picker(ZtatL10n.tr("温度单位", "Temperature Unit"), selection: Binding(
                    get: { temperatureUnit },
                    set: { newVal in
                        temperatureUnit = newVal
                        Store.shared.set(key: "temperature_units", value: newVal)
                    }
                )) {
                    Text(ZtatL10n.tr("跟随系统", "System")).tag("system")
                    Text("°C (" + ZtatL10n.tr("摄氏度", "Celsius") + ")").tag("celsius")
                    Text("°F (" + ZtatL10n.tr("华氏度", "Fahrenheit") + ")").tag("fahrenheit")
                }

                Toggle(
                    ZtatL10n.tr("保留菜单栏监控项位置", "Keep Menu Bar Item Positions"),
                    isOn: Binding(
                        get: { keepMenuBarPosition },
                        set: { newVal in
                            keepMenuBarPosition = newVal
                            Store.shared.set(key: "keep_menubar_positions", value: newVal)
                        }
                    )
                )
            }

            Section(ZtatL10n.tr("菜单栏弹窗融合风格", "Menu Bar Popover Style")) {
                Toggle(
                    ZtatL10n.tr("优先使用 Vitals 融合硬件详情弹窗（按住 ⌥ 点击可切换经典 Stats 弹窗）", "Use Unified Vitals Popover by Default (⌥+Click for Classic Stats Popup)"),
                    isOn: Binding(
                        get: { Store.shared.bool(key: "VitalsUnifiedPopover", defaultValue: true) },
                        set: { newVal in
                            Store.shared.set(key: "VitalsUnifiedPopover", value: newVal)
                            host.refreshSummaries()
                        }
                    )
                )
            }

            Section(ZtatL10n.tr("合并菜单栏模式 (Combine Modules)", "Combined Menu Bar Mode")) {
                Toggle(
                    ZtatL10n.tr("合并所有已启用监控模块为单个菜单栏项", "Combine Active Monitors into One Menu Bar Item"),
                    isOn: Binding(
                        get: { host.isCombinedModulesEnabled },
                        set: { host.setCombinedModulesEnabled($0) }
                    )
                )

                if host.isCombinedModulesEnabled {
                    Picker(ZtatL10n.tr("合并显示样式", "Combined Display Style"), selection: Binding(
                        get: { combinedDisplay },
                        set: { newVal in
                            combinedDisplay = newVal
                            if let widget = CombinedModulesWidget(rawValue: newVal) {
                                CombinedModulesWidget.current = widget
                            }
                            NotificationCenter.default.post(name: .moduleRearrange, object: nil, userInfo: nil)
                        }
                    )) {
                        ForEach(CombinedModulesWidget.all, id: \.key) { item in
                            Text(localizedString(item.value)).tag(item.key)
                        }
                    }

                    if combinedDisplay == CombinedModulesWidget.widgets.rawValue {
                        Picker(ZtatL10n.tr("模块间距", "Spacing"), selection: Binding(
                            get: { combinedSpacing },
                            set: { newVal in
                                combinedSpacing = newVal
                                Store.shared.set(key: "CombinedModules_spacing", value: newVal)
                                NotificationCenter.default.post(name: .moduleRearrange, object: nil, userInfo: nil)
                            }
                        )) {
                            ForEach(CombinedModulesSpacings, id: \.key) { item in
                                Text(localizedString(item.value)).tag(item.key)
                            }
                        }

                        Toggle(
                            ZtatL10n.tr("模块间显示分隔线", "Show Separator Between Modules"),
                            isOn: Binding(
                                get: { combinedSeparator },
                                set: { newVal in
                                    combinedSeparator = newVal
                                    Store.shared.set(key: "CombinedModules_separator", value: newVal)
                                    NotificationCenter.default.post(name: .moduleRearrange, object: nil, userInfo: nil)
                                }
                            )
                        )
                    }

                    if !orderedIDs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ZtatL10n.tr("合并顺序（拖拽或使用箭头排序）", "Combined Order"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(Array(orderedIDs.enumerated()), id: \.element) { idx, modID in
                                let summary = host.moduleSummary(for: modID)
                                HStack(spacing: 8) {
                                    Image(systemName: summary?.symbolName ?? "gauge.with.dots.needle.67percent")
                                        .frame(width: 16)
                                        .foregroundStyle(summary?.isEnabled == true ? Color.accentColor : Color.secondary)
                                    Text(summary?.displayName ?? modID)
                                        .font(.callout)
                                    Spacer()
                                    Button {
                                        guard idx > 0 else { return }
                                        host.moveModules(fromOffsets: IndexSet(integer: idx), toOffset: idx - 1)
                                        orderedIDs = host.orderedModuleIDs()
                                    } label: {
                                        Image(systemName: "chevron.up")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(idx == 0)

                                    Button {
                                        guard idx + 1 < orderedIDs.count else { return }
                                        host.moveModules(fromOffsets: IndexSet(integer: idx), toOffset: idx + 2)
                                        orderedIDs = host.orderedModuleIDs()
                                    } label: {
                                        Image(systemName: "chevron.down")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(idx + 1 >= orderedIDs.count)
                                }
                            }
                        }
                    }
                }
            }

            Section(ZtatL10n.tr("配置备份与重置", "Backup & Reset")) {
                HStack {
                    Text(ZtatL10n.tr("导出性能监控配置 (.plist)", "Export Monitor Configuration (.plist)"))
                    Spacer()
                    Button(ZtatL10n.tr("导出…", "Export…")) { exportStatsConfig() }
                }
                HStack {
                    Text(ZtatL10n.tr("导入性能监控配置（实时生效）", "Import Monitor Configuration (Applies Live)"))
                    Spacer()
                    Button(ZtatL10n.tr("选择文件…", "Choose File…")) { importStatsConfig() }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ZtatL10n.tr("重置全部性能监控偏好", "Reset All Monitor Preferences"))
                        Text(ZtatL10n.tr("仅重置独立监控模块配置，不影响状态图标、保活与工具箱。", "Resets only Hardware Monitor settings without touching Status, PowerGuard, or Toolbox."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(ZtatL10n.tr("重置", "Reset"), role: .destructive) {
                        showResetConfirmation = true
                    }
                }
            }

            #if arch(arm64)
            Section(ZtatL10n.tr("Apple Silicon 压力测试", "Apple Silicon Stress Tests")) {
                let cpu = SystemKit.shared.device.info.cpu
                if (cpu?.eCores ?? 0) > 0 {
                    stressRow(ZtatL10n.tr("能效核心 (E-Cores)", "Efficiency Cores"), running: eRunning) {
                        if eCoreTest.isRunning { eCoreTest.stop() } else { eCoreTest.start() }
                        eRunning = eCoreTest.isRunning
                    }
                }
                if (cpu?.pCores ?? 1) > 0 {
                    stressRow(ZtatL10n.tr("性能核心 (P-Cores)", "Performance Cores"), running: pRunning) {
                        if pCoreTest.isRunning { pCoreTest.stop() } else { pCoreTest.start() }
                        pRunning = pCoreTest.isRunning
                    }
                }
                if (cpu?.sCores ?? 0) > 0 {
                    stressRow(ZtatL10n.tr("超级核心 (S-Cores)", "Super Cores"), running: sRunning) {
                        if sCoreTest.isRunning { sCoreTest.stop() } else { sCoreTest.start() }
                        sRunning = sCoreTest.isRunning
                    }
                }
                if gpuTest != nil {
                    stressRow(ZtatL10n.tr("图形处理器 (GPU)", "GPU"), running: gpuRunning) {
                        guard let gpuTest else { return }
                        if gpuTest.isRunning { gpuTest.stop() } else { gpuTest.start() }
                        gpuRunning = gpuTest.isRunning
                    }
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .onAppear { reloadStateFromStore() }
        .onReceive(NotificationCenter.default.publisher(for: .ztatStatsStoreDidChange)) { _ in
            reloadStateFromStore()
        }
        .onDisappear {
            if eCoreTest.isRunning { eCoreTest.stop(); eRunning = false }
            if pCoreTest.isRunning { pCoreTest.stop(); pRunning = false }
            if sCoreTest.isRunning { sCoreTest.stop(); sRunning = false }
            if let gpuTest, gpuTest.isRunning { gpuTest.stop(); gpuRunning = false }
        }
        .alert(
            ZtatL10n.tr("确认重置性能监控设置？", "Reset Hardware Monitor Preferences?"),
            isPresented: $showResetConfirmation
        ) {
            Button(ZtatL10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(ZtatL10n.tr("重置", "Reset"), role: .destructive) {
                host.resetAllStatsPreferences()
                reloadStateFromStore()
            }
        } message: {
            Text(ZtatL10n.tr("这将关闭所有菜单栏监控项并恢复性能监控默认设置。", "All menu bar monitors will be disabled and Hardware Monitor settings will be restored to defaults."))
        }
    }

    private func stressRow(_ title: String, running: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(running ? ZtatL10n.tr("停止", "Stop") : ZtatL10n.tr("运行", "Run"), action: action)
                .tint(running ? .red : .accentColor)
        }
    }

    private func reloadStateFromStore() {
        temperatureUnit = Store.shared.string(key: "temperature_units", defaultValue: "system")
        keepMenuBarPosition = Store.shared.bool(key: "keep_menubar_positions", defaultValue: false)
        combinedDisplay = CombinedModulesWidget.current.rawValue
        combinedSpacing = Store.shared.string(key: "CombinedModules_spacing", defaultValue: "none")
        combinedSeparator = Store.shared.bool(key: "CombinedModules_separator", defaultValue: false)
        orderedIDs = host.orderedModuleIDs()
    }

    private func exportStatsConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ztat-monitor-settings.plist"
        panel.showsTagField = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Store.shared.export(to: url)
        }
    }

    private func importStatsConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Store.shared.import(from: url)
            Task { @MainActor in
                host.reloadAllFromStore()
                reloadStateFromStore()
            }
        }
    }
}
