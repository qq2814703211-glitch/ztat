// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Native Vitals-Style Unified Popover & Hardware Inspector Views.
// Features real live sparklines, clickable hardware overview cards, and 13 dedicated
// hardware & developer drill-down panes backed 100% by VitalsHardwareTelemetry & VitalsProcessEngine.

import AppKit
import CoreAudio
import SwiftUI
import ZtatCore

// MARK: - Shared Formatting & Reusable Chart Components

public enum VitalsFormat {
    public static func memoryMB(_ mb: Double) -> String {
        if mb >= 1024.0 {
            return String(format: "%.2f GB", mb / 1024.0)
        }
        return String(format: "%.0f MB", max(0, mb))
    }

    public static func bytes(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b >= 1_073_741_824 { return String(format: "%.2f GB", b / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.1f MB", b / 1_048_576) }
        if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
        return "\(bytes) B"
    }

    public static func rateBps(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        if bps >= 1024 { return String(format: "%.0f KB/s", bps / 1024) }
        if bps < 1 { return "0 B/s" }
        return String(format: "%.0f B/s", bps)
    }

    public static func speedKBs(_ kbs: Double) -> String {
        if kbs >= 1024.0 {
            return String(format: "%.1f MB/s", kbs / 1024.0)
        }
        return String(format: "%.0f KB/s", max(0, kbs))
    }

    public static func cpuTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        let tenths = Int((seconds - floor(seconds)) * 10)
        return String(format: "%d:%02d.%d", m, s, max(0, min(9, tenths)))
    }

    public static func minutes(_ mins: Int) -> String {
        let h = mins / 60
        let m = mins % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private static let iconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()

    public static func appIcon(for bundleURL: URL?) -> Image {
        if let url = bundleURL {
            let key = url.path as NSString
            if let cached = iconCache.object(forKey: key) {
                return Image(nsImage: cached)
            }
            let img = NSWorkspace.shared.icon(forFile: url.path)
            iconCache.setObject(img, forKey: key)
            return Image(nsImage: img)
        }
        return Image(systemName: "terminal.fill")
    }
}

public struct VitalsSparkline: View {
    public let values: [Double]
    public let color: Color
    public var fixedMax: Double? = nil
    public var secondaryValues: [Double]? = nil
    public var secondaryColor: Color = .purple

    public init(values: [Double], color: Color, fixedMax: Double? = nil, secondaryValues: [Double]? = nil, secondaryColor: Color = .purple) {
        self.values = values
        self.color = color
        self.fixedMax = fixedMax
        self.secondaryValues = secondaryValues
        self.secondaryColor = secondaryColor
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxVal: Double = {
                if let fixed = fixedMax, fixed > 0 { return fixed }
                let m1 = values.max() ?? 0
                let m2 = secondaryValues?.max() ?? 0
                return max(m1, m2, 0.001)
            }()

            ZStack {
                if values.count >= 2 {
                    areaPath(values, width: w, height: h, maxVal: maxVal)
                        .fill(LinearGradient(
                            colors: [color.opacity(0.28), color.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                    linePath(values, width: w, height: h, maxVal: maxVal)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                } else {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h - 1))
                        p.addLine(to: CGPoint(x: w, y: h - 1))
                    }
                    .stroke(color.opacity(0.25), lineWidth: 1)
                }

                if let sec = secondaryValues, sec.count >= 2 {
                    linePath(sec, width: w, height: h, maxVal: maxVal)
                        .stroke(secondaryColor, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func linePath(_ pts: [Double], width: CGFloat, height: CGFloat, maxVal: Double) -> Path {
        Path { path in
            let step = width / CGFloat(max(1, pts.count - 1))
            for (idx, val) in pts.enumerated() {
                let x = CGFloat(idx) * step
                let norm = min(1.0, max(0.0, val / maxVal))
                let y = height - CGFloat(norm) * (height - 2) - 1
                if idx == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }

    private func areaPath(_ pts: [Double], width: CGFloat, height: CGFloat, maxVal: Double) -> Path {
        var path = linePath(pts, width: width, height: height, maxVal: maxVal)
        path.addLine(to: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: 0, y: height))
        path.closeSubpath()
        return path
    }
}

public struct VisualEffectBackground: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
        return view
    }
    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Main Vitals Popover View

public struct VitalsDashboardView: View {
    @ObservedObject public var model: VitalsDashboardModel

    public init(model: VitalsDashboardModel? = nil) {
        self.model = model ?? VitalsDashboardModel.shared
    }

    public var body: some View {
        VStack(spacing: 0) {
            topHeaderBar
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            paneTabStrip
                .padding(.bottom, 8)

            Divider().opacity(0.28)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    if let feedback = model.actionFeedback {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(feedback)
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
                    }

                    VitalsPaneContentRouter(
                        model: model,
                        pane: model.activePane,
                        isCompactPopover: true,
                        onSelectPane: { pane in
                            withAnimation(.easeInOut(duration: 0.16)) { model.activePane = pane }
                        }
                    )
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.28)

            bottomStatusBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.025))
        }
        .frame(width: 520)
        .frame(maxHeight: .infinity)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.75)
        )
    }

    private var topHeaderBar: some View {
        HStack(spacing: 8) {
            if model.activePane != .overview {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.activePane = .overview
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10.5, weight: .bold))
                        Text(ZtatL10n.tr("概览", "Overview"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.13)))
                }
                .buttonStyle(.plain)
            }

            Image(systemName: model.activePane.symbol)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 0) {
                Text(model.activePane.title)
                    .font(.system(size: 13, weight: .bold))
                if model.activePane == .overview && !model.hardware.chipName.isEmpty {
                    Text(model.hardware.chipName)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                VitalsPopoverWindow.shared.dismiss()
                NotificationCenter.default.post(name: .ztatOpenTaskManager, object: nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle.portrait.fill")
                        .font(.system(size: 10.5))
                    Text(ZtatL10n.tr("任务管理器", "Task Manager"))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(ZtatL10n.tr("打开完整任务管理器（替代原生活动监视器）", "Open Full Activity Monitor"))

            Button {
                VitalsPopoverWindow.shared.dismiss()
                NotificationCenter.default.post(name: .ztatOpenSettings, object: ZtatSettingsRoute.stats(target: "overview"))
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(ZtatL10n.tr("打开 ztat 硬件监控设置", "Open Hardware Monitor Settings"))
        }
    }

    private var paneTabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(visiblePanes) { pane in
                    let selected = model.activePane == pane
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            model.activePane = pane
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: pane.symbol)
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(pane.shortLabel)
                                .font(.system(size: 10.5, weight: selected ? .bold : .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.06))
                        )
                        .foregroundStyle(selected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private var visiblePanes: [VitalsPane] {
        VitalsPane.allCases.filter { pane in
            if pane == .ane && !model.hardware.aneSupported { return false }
            return true
        }
    }

    private var bottomStatusBar: some View {
        HStack(spacing: 10) {
            Label(ZtatL10n.tr("运行 \(model.uptimeFormatted)", "Up \(model.uptimeFormatted)"), systemImage: "clock")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if let totalW = model.hardware.powerRails.systemTotalWatts ?? (model.hardware.powerRails.packageTotalWatts > 0 ? model.hardware.powerRails.packageTotalWatts : nil) {
                Label(String(format: "%.1fW", totalW), systemImage: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
            }

            if let hot = model.hardware.hottestTempC {
                Label(String(format: "%.0f°C", hot), systemImage: "thermometer.medium")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(hot > 80 ? .red : (hot > 65 ? .orange : .secondary))
            }

            Spacer()

            Text("\(model.processes.count) \(ZtatL10n.tr("进程", "procs")) · \(model.totalThreadCount) \(ZtatL10n.tr("线程", "threads"))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                model.refresh(forceSlowScans: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(ZtatL10n.tr("立即刷新", "Refresh Now"))
        }
    }
}

// MARK: - Shared Pane Router (Reused by both Popover & Task Manager Hardware Tab)

public struct VitalsPaneContentRouter: View {
    @ObservedObject public var model: VitalsDashboardModel
    public let pane: VitalsPane
    public let isCompactPopover: Bool
    public let onSelectPane: ((VitalsPane) -> Void)?

    public init(
        model: VitalsDashboardModel,
        pane: VitalsPane,
        isCompactPopover: Bool,
        onSelectPane: ((VitalsPane) -> Void)? = nil
    ) {
        self.model = model
        self.pane = pane
        self.isCompactPopover = isCompactPopover
        self.onSelectPane = onSelectPane
    }

    public var body: some View {
        switch pane {
        case .overview:
            VitalsOverviewGridView(model: model, isCompactPopover: isCompactPopover, onSelectPane: onSelectPane)
        case .cpu:
            VitalsCPUPaneView(model: model)
        case .gpu:
            VitalsGPUPaneView(model: model, onSelectPane: onSelectPane)
        case .ane:
            VitalsANEPaneView(model: model)
        case .memory:
            VitalsMemoryPaneView(model: model)
        case .disk:
            VitalsDiskPaneView(model: model)
        case .network:
            VitalsNetworkPaneView(model: model, onSelectPane: onSelectPane)
        case .battery:
            VitalsBatteryPaneView(model: model)
        case .fans:
            VitalsFansPaneView(model: model)
        case .bluetooth:
            VitalsBluetoothPaneView(model: model)
        case .sound:
            VitalsSoundPaneView(model: model)
        case .agents:
            VitalsAgentsPaneView(model: model)
        case .containers:
            VitalsContainersPaneView(model: model)
        case .ports:
            VitalsPortsPaneView(model: model)
        }
    }
}

// MARK: - Overview Grid (Clickable Interactive Hardware Tiles)

public struct VitalsOverviewGridView: View {
    @ObservedObject public var model: VitalsDashboardModel
    public let isCompactPopover: Bool
    public let onSelectPane: ((VitalsPane) -> Void)?

    public init(model: VitalsDashboardModel, isCompactPopover: Bool, onSelectPane: ((VitalsPane) -> Void)? = nil) {
        self.model = model
        self.isCompactPopover = isCompactPopover
        self.onSelectPane = onSelectPane
    }

    private func navigate(to pane: VitalsPane) {
        if let onSelectPane {
            onSelectPane(pane)
        } else {
            withAnimation(.easeInOut(duration: 0.16)) { model.activePane = pane }
        }
    }

    private var hw: VitalsHardwareSnapshot { model.hardware }

    private var memoryColor: Color {
        switch hw.memory.level {
        case .critical: return .red
        case .warning: return .orange
        case .normal: return .green
        }
    }

    public var body: some View {
        let columns = isCompactPopover
            ? [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)]
            : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

        VStack(alignment: .leading, spacing: 10) {
            // Live Health / Strain Diagnostics Banner
            if !model.healthAlerts.isEmpty {
                VStack(spacing: 5) {
                    ForEach(model.healthAlerts.prefix(2)) { alert in
                        Button {
                            navigate(to: alert.targetPane)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: alert.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(alert.severity == .critical ? .red : .orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(alert.title)
                                        .font(.system(size: 11, weight: .bold))
                                    Text(alert.detail)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill((alert.severity == .critical ? Color.red : Color.orange).opacity(0.11))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 8 Interactive Hardware Cards with Real Sparklines
            LazyVGrid(columns: columns, spacing: 9) {
                // 1. CPU
                hardwareTile(
                    pane: .cpu,
                    title: "CPU",
                    value: String(format: "%.0f%%", hw.cpuUsage * 100),
                    subtitle: cpuSubtitle,
                    color: .blue,
                    symbol: "cpu",
                    history: model.cpuHistory,
                    fixedMax: 1.0,
                    footerLeft: String(format: ZtatL10n.tr("用户 %.0f%% · 系统 %.0f%%", "Usr %.0f%% · Sys %.0f%%"), hw.cpuUser * 100, hw.cpuSystem * 100),
                    footerRight: hw.cpuTempC.map { String(format: "%.0f°C", $0) } ?? String(format: "%.1fW", hw.powerRails.cpuWatts)
                )

                // 2. GPU
                hardwareTile(
                    pane: .gpu,
                    title: "GPU",
                    value: String(format: "%.0f%%", hw.gpuUsage * 100),
                    subtitle: hw.gpuCoreCount > 0 ? "\(hw.gpuName) · \(hw.gpuCoreCount)核" : hw.gpuName,
                    color: .indigo,
                    symbol: "rectangle.3.group",
                    history: model.gpuHistory,
                    fixedMax: 1.0,
                    footerLeft: String(format: ZtatL10n.tr("显存 %.1f GB", "VRAM %.1f GB"), hw.gpuInUseMB / 1024.0),
                    footerRight: hw.gpuTempC.map { String(format: "%.0f°C", $0) } ?? (hw.displayFPS.map { String(format: "%.0f FPS", $0) } ?? String(format: "%.1fW", hw.powerRails.gpuWatts))
                )

                // 3. Memory
                hardwareTile(
                    pane: .memory,
                    title: ZtatL10n.tr("内存", "Memory"),
                    value: String(format: "%.1f GB", hw.memory.usedGB),
                    subtitle: String(format: "/ %.0f GB · %@", hw.memory.totalGB, hw.memory.level.label),
                    color: memoryColor,
                    symbol: "memorychip",
                    history: model.memHistory,
                    fixedMax: 1.0,
                    footerLeft: String(format: ZtatL10n.tr("压缩 %.1fG", "Comp %.1fG"), hw.memory.compressedGB),
                    footerRight: String(format: "Swap %.1fG", hw.memory.swapUsedGB)
                )

                // 4. Disk
                let rootVol = hw.diskVolumes.first
                hardwareTile(
                    pane: .disk,
                    title: ZtatL10n.tr("磁盘", "Disk"),
                    value: rootVol.map { String(format: "%.0f%%", $0.usedFraction * 100) } ?? "—",
                    subtitle: rootVol.map { String(format: ZtatL10n.tr("剩余 %.0f GB", "%.0f GB free"), $0.freeGB) } ?? "—",
                    color: .purple,
                    symbol: "internaldrive",
                    history: model.diskReadHistory,
                    secondaryHistory: model.diskWriteHistory,
                    secondaryColor: .pink,
                    footerLeft: String(format: "R %.1f MB/s", hw.diskReadMBs),
                    footerRight: String(format: "W %.1f MB/s", hw.diskWriteMBs)
                )

                // 5. Network
                hardwareTile(
                    pane: .network,
                    title: ZtatL10n.tr("网络", "Network"),
                    value: "↓ " + VitalsFormat.speedKBs(hw.netDownloadKBs),
                    subtitle: hw.wifiSSID ?? "\(hw.activeInterfaceName) · \(hw.localIPv4)",
                    color: .teal,
                    symbol: "arrow.up.arrow.down",
                    history: model.netDownHistory,
                    secondaryHistory: model.netUpHistory,
                    secondaryColor: .cyan,
                    footerLeft: "↑ " + VitalsFormat.speedKBs(hw.netUploadKBs),
                    footerRight: hw.localIPv4
                )

                // 6. Battery & Power
                let batVal: String = {
                    if let pct = hw.batteryPercent { return "\(pct)%" }
                    if let w = hw.powerRails.systemTotalWatts { return String(format: "%.0fW", w) }
                    return "AC"
                }()
                let batSub: String = {
                    if let mins = hw.batteryTimeRemainingMinutes, mins > 0 {
                        return hw.batteryCharging
                            ? ZtatL10n.tr("约 \(VitalsFormat.minutes(mins)) 充满", "\(VitalsFormat.minutes(mins)) to full")
                            : ZtatL10n.tr("剩余 \(VitalsFormat.minutes(mins))", "\(VitalsFormat.minutes(mins)) left")
                    }
                    if hw.batteryFullyCharged { return ZtatL10n.tr("已充满 · 电源供电", "Fully Charged") }
                    return hw.batteryExternalConnected ? ZtatL10n.tr("电源适配器供电", "Power Adapter") : ZtatL10n.tr("电池供电", "On Battery")
                }()
                hardwareTile(
                    pane: .battery,
                    title: ZtatL10n.tr("电池与功耗", "Power"),
                    value: batVal,
                    subtitle: batSub,
                    color: hw.batteryCharging ? .green : .orange,
                    symbol: hw.batteryCharging ? "battery.100.bolt" : "bolt.fill",
                    history: model.powerHistory,
                    footerLeft: hw.powerRails.systemTotalWatts.map { String(format: ZtatL10n.tr("整机 %.1fW", "Sys %.1fW"), $0) }
                        ?? (hw.batteryWatts.map { String(format: "%.1fW", $0) } ?? "—"),
                    footerRight: hw.batteryHealthPercent.map { String(format: ZtatL10n.tr("健康 %.0f%%", "Health %.0f%%"), $0) } ?? "—"
                )

                // 7. Thermals & Fans
                let fanText: String = {
                    if let fastest = hw.fans.max(by: { $0.currentRPM < $1.currentRPM }) {
                        return "\(Int(fastest.currentRPM.rounded())) RPM"
                    }
                    return ZtatL10n.tr("无风扇/静音", "Fanless")
                }()
                hardwareTile(
                    pane: .fans,
                    title: ZtatL10n.tr("温控与风扇", "Thermals"),
                    value: hw.hottestTempC.map { String(format: "%.0f°C", $0) } ?? "—",
                    subtitle: hw.hottestSensorName ?? thermalLabel,
                    color: thermalColor,
                    symbol: "fanblades",
                    history: model.tempHistory,
                    fixedMax: 105,
                    footerLeft: fanText,
                    footerRight: thermalLabel
                )

                // 8. Neural Engine (or Bluetooth/Audio on Intel)
                if hw.aneSupported {
                    hardwareTile(
                        pane: .ane,
                        title: ZtatL10n.tr("神经网络引擎", "Neural Engine"),
                        value: String(format: "%.1fW", hw.powerRails.aneWatts),
                        subtitle: String(format: ZtatL10n.tr("利用率 %.0f%% · Apple ANE", "Load %.0f%% · Apple ANE"), hw.aneUtilization * 100),
                        color: .pink,
                        symbol: "brain.head.profile",
                        history: model.aneHistory,
                        fixedMax: 1.0,
                        footerLeft: String(format: "DRAM %.1fW", hw.powerRails.dramWatts),
                        footerRight: String(format: ZtatL10n.tr("上限 %.0fW", "Max %.0fW"), hw.aneMaxPowerWatts)
                    )
                } else {
                    hardwareTile(
                        pane: .sound,
                        title: ZtatL10n.tr("音频与蓝牙", "Sound & BT"),
                        value: hw.isSystemMuted ? ZtatL10n.tr("静音", "Muted") : "\(Int((hw.systemVolume * 100).rounded()))%",
                        subtitle: hw.activeOutputAudioName,
                        color: .cyan,
                        symbol: "speaker.wave.2.fill",
                        history: [],
                        footerLeft: ZtatL10n.tr("蓝牙 \(hw.bluetoothDevices.count) 台", "\(hw.bluetoothDevices.count) BT"),
                        footerRight: hw.activeInputAudioName
                    )
                }
            }

            // Quick Developer, Peripherals & Runtime Strip
            HStack(spacing: 7) {
                quickPill(pane: .agents, title: ZtatL10n.tr("AI 智能体", "Agents"), count: "\(model.agentSessions.count)", color: .orange)
                quickPill(pane: .ports, title: ZtatL10n.tr("监听端口", "Ports"), count: "\(model.listeningPorts.count)", color: .blue)
                quickPill(pane: .containers, title: ZtatL10n.tr("容器", "Docker"), count: "\(model.containers.count)", color: .cyan)
                quickPill(pane: .bluetooth, title: ZtatL10n.tr("蓝牙", "BT"), count: "\(hw.bluetoothDevices.count)", color: .indigo)
                quickPill(pane: .sound, title: ZtatL10n.tr("音频", "Sound"), count: hw.isSystemMuted ? "🔇" : "\(Int((hw.systemVolume * 100).rounded()))%", color: .pink)
            }

            // Top App Groups Glance (Grouped with helpers folded like Vitals!)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(ZtatL10n.tr("高负载应用（按应用聚合子进程）", "Top Applications (Helpers Folded)"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isCompactPopover {
                        Button {
                            VitalsPopoverWindow.shared.dismiss()
                            NotificationCenter.default.post(name: .ztatOpenTaskManager, object: nil)
                        } label: {
                            Text(ZtatL10n.tr("打开任务管理器 ↗", "Task Manager ↗"))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }

                ForEach(model.appGroups.prefix(isCompactPopover ? 5 : 8)) { group in
                    HStack(spacing: 8) {
                        VitalsFormat.appIcon(for: group.bundleURL)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)

                        Text(group.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)

                        if group.processCount > 1 {
                            Text("\(group.processCount)")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .foregroundStyle(.secondary)
                        }

                        if !group.ports.isEmpty {
                            Text(":\(group.ports[0])")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.blue.opacity(0.14)))
                                .foregroundStyle(.blue)
                        }

                        Spacer()

                        Text(String(format: "%.1f%%", group.totalCPU))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(group.totalCPU > 50 ? .orange : .blue)
                            .frame(width: 48, alignment: .trailing)

                        Text(VitalsFormat.memoryMB(group.totalMemoryMB))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)

                        if group.bundleURL != nil && !group.id.hasPrefix("svc:") && !group.id.hasPrefix("sys:") {
                            Button {
                                model.terminateAppGroup(group, force: false)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(ZtatL10n.tr("退出 \(group.name)", "Quit \(group.name)"))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }

    private var cpuSubtitle: String {
        let sCount = hw.coreSamples.filter(\.isSuper).count
        let pCount = hw.coreSamples.filter { !$0.isSuper && $0.isPerformance }.count
        let eCount = hw.coreSamples.filter { !$0.isSuper && !$0.isPerformance }.count
        let loadStr = String(format: "%.2f", hw.loadAverages.first ?? 0)
        if sCount > 0 && pCount > 0 && eCount > 0 {
            return "\(sCount)S + \(pCount)P + \(eCount)E · Load \(loadStr)"
        }
        if sCount > 0 && pCount > 0 {
            return "\(sCount)S + \(pCount)P · Load \(loadStr)"
        }
        if pCount > 0 && eCount > 0 {
            return "\(pCount)P + \(eCount)E · Load \(loadStr)"
        }
        return "\(hw.coreSamples.count) \(ZtatL10n.tr("核心", "Cores")) · Load \(loadStr)"
    }

    private var thermalLabel: String {
        switch hw.thermalState {
        case .nominal: return ZtatL10n.tr("良好", "Nominal")
        case .fair: return ZtatL10n.tr("温热", "Fair")
        case .serious: return ZtatL10n.tr("偏热", "Serious")
        case .critical: return ZtatL10n.tr("过热", "Critical")
        @unknown default: return "—"
        }
    }

    private var thermalColor: Color {
        switch hw.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    private func hardwareTile(
        pane: VitalsPane,
        title: String,
        value: String,
        subtitle: String,
        color: Color,
        symbol: String,
        history: [Double],
        fixedMax: Double? = nil,
        secondaryHistory: [Double]? = nil,
        secondaryColor: Color = .purple,
        footerLeft: String,
        footerRight: String
    ) -> some View {
        Button {
            navigate(to: pane)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                    Text(title)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                    Spacer()
                    Text(value)
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(color)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }

                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                VitalsSparkline(
                    values: history,
                    color: color,
                    fixedMax: fixedMax,
                    secondaryValues: secondaryHistory,
                    secondaryColor: secondaryColor
                )
                .frame(height: 22)

                HStack {
                    Text(footerLeft)
                        .lineLimit(1)
                    Spacer()
                    Text(footerRight)
                        .lineLimit(1)
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func quickPill(pane: VitalsPane, title: String, count: String, color: Color) -> some View {
        Button {
            navigate(to: pane)
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(color)
                    Text(count)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.09)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 1. CPU Detail Pane

public struct VitalsCPUPaneView: View {
    @ObservedObject public var model: VitalsDashboardModel
    private var hw: VitalsHardwareSnapshot { model.hardware }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hw.chipName)
                            .font(.system(size: 12.5, weight: .bold))
                        Text(String(format: ZtatL10n.tr("用户 %.1f%% · 系统 %.1f%% · 空闲 %.1f%%", "User %.1f%% · System %.1f%% · Idle %.1f%%"),
                                    hw.cpuUser * 100, hw.cpuSystem * 100, hw.cpuIdle * 100))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.1f%%", hw.cpuUsage * 100))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(.blue)
                }

                VitalsSparkline(values: model.cpuHistory, color: .blue, fixedMax: 1.0)
                    .frame(height: 52)

                HStack {
                    Label(String(format: "Load %.2f / %.2f / %.2f", hw.loadAverages[0], hw.loadAverages[1], hw.loadAverages[2]), systemImage: "waveform.path.ecg")
                    Spacer()
                    if hw.powerRails.cpuWatts > 0 {
                        Text(String(format: "CPU %.1fW", hw.powerRails.cpuWatts))
                            .foregroundStyle(.orange)
                    }
                    if let t = hw.cpuTempC {
                        Text(String(format: "%.0f°C", t))
                            .foregroundStyle(t > 80 ? .red : .secondary)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            // Per-Core Super / Performance / Efficiency Grid
            let sCores = hw.coreSamples.filter(\.isSuper)
            let pCores = hw.coreSamples.filter { $0.isPerformance && !$0.isSuper }
            let eCores = hw.coreSamples.filter { !$0.isPerformance }
            let tierCount = [sCores.isEmpty, pCores.isEmpty, eCores.isEmpty].filter { !$0 }.count

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(ZtatL10n.tr("各逻辑核心实时负载", "Per-Core Live Utilization"))
                        .font(.system(size: 11.5, weight: .bold))
                    Spacer()
                    if !sCores.isEmpty && !pCores.isEmpty {
                        Text("\(sCores.count) \(ZtatL10n.tr("超级核", "S-Cores")) · \(pCores.count) \(ZtatL10n.tr("性能核", "P-Cores"))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    } else if !eCores.isEmpty && !pCores.isEmpty {
                        Text("\(pCores.count) \(ZtatL10n.tr("性能核", "P-Cores")) · \(eCores.count) \(ZtatL10n.tr("能效核", "E-Cores"))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }

                if !sCores.isEmpty {
                    coreGroupSection(title: tierCount > 1 ? ZtatL10n.tr("超级核心 (Super Cores)", "Super Cores") : nil, cores: sCores, tint: .indigo)
                }
                if !pCores.isEmpty {
                    coreGroupSection(title: tierCount > 1 ? ZtatL10n.tr("性能核心 (P-Cores)", "Performance Cores") : nil, cores: pCores, tint: .blue)
                }
                if !eCores.isEmpty {
                    coreGroupSection(title: ZtatL10n.tr("能效核心 (E-Cores)", "Efficiency Cores"), cores: eCores, tint: .teal)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            // Top CPU Processes
            VStack(alignment: .leading, spacing: 6) {
                Text(ZtatL10n.tr("CPU 占用最高的进程", "Top CPU Consumers"))
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.secondary)

                ForEach(model.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(7)) { proc in
                    HStack(spacing: 8) {
                        VitalsFormat.appIcon(for: proc.bundleURL)
                            .resizable().scaledToFit().frame(width: 15, height: 15)
                        Text(proc.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Text("PID \(proc.id)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("\(proc.threads)T")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f%%", proc.cpuPercent))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.blue)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }

    private func coreGroupSection(title: String?, cores: [VitalsCoreSample], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)], spacing: 6) {
                ForEach(cores) { core in
                    VStack(spacing: 3) {
                        HStack {
                            Text(core.tierLabel)
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int((core.load * 100).rounded()))%")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        }
                        ProgressView(value: core.load)
                            .tint(core.load > 0.85 ? .red : (core.load > 0.55 ? .orange : tint))
                    }
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }
            }
        }
    }
}

// MARK: - 2. GPU Detail Pane

public struct VitalsGPUPaneView: View {
    @ObservedObject public var model: VitalsDashboardModel
    public let onSelectPane: ((VitalsPane) -> Void)?
    private var hw: VitalsHardwareSnapshot { model.hardware }

    public init(model: VitalsDashboardModel, onSelectPane: ((VitalsPane) -> Void)? = nil) {
        self.model = model
        self.onSelectPane = onSelectPane
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hw.gpuName)
                            .font(.system(size: 13, weight: .bold))
                        HStack(spacing: 6) {
                            if hw.gpuCoreCount > 0 {
                                Text("\(hw.gpuCoreCount) \(ZtatL10n.tr("核 GPU", "GPU Cores"))")
                            }
                            Text(hw.gpuHasUnifiedMemory ? ZtatL10n.tr("统一内存架构", "Unified Memory") : ZtatL10n.tr("独立显存", "Discrete VRAM"))
                            if let fps = hw.displayFPS {
                                Text(String(format: "· %.0f FPS", fps))
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.0f%%", hw.gpuUsage * 100))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(.indigo)
                }

                VitalsSparkline(values: model.gpuHistory, color: .indigo, fixedMax: 1.0)
                    .frame(height: 52)

                HStack {
                    if hw.powerRails.gpuWatts > 0 {
                        Label(String(format: "GPU %.1fW", hw.powerRails.gpuWatts), systemImage: "bolt.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if let temp = hw.gpuTempC {
                        Label(String(format: "%.0f°C", temp), systemImage: "thermometer.medium")
                            .foregroundStyle(temp > 80 ? .red : .secondary)
                    }
                }
                .font(.system(size: 10.5, design: .monospaced))
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            // Pipeline Utilization Breakdown
            VStack(alignment: .leading, spacing: 8) {
                Text(ZtatL10n.tr("GPU 管线与显存分配", "GPU Pipeline & Memory Allocation"))
                    .font(.system(size: 11.5, weight: .bold))

                metricBar(label: ZtatL10n.tr("设备总利用率 (Device)", "Device Utilization"), value: hw.gpuUsage, color: .indigo)
                metricBar(label: ZtatL10n.tr("渲染管线 (Renderer)", "Renderer Utilization"), value: hw.gpuRendererUtilization, color: .purple)
                metricBar(label: ZtatL10n.tr("分块光栅化 (Tiler)", "Tiler Utilization"), value: hw.gpuTilerUtilization, color: .cyan)

                Divider().opacity(0.3)

                HStack(spacing: 12) {
                    statBox(title: ZtatL10n.tr("正在使用显存", "In-Use VRAM"), value: VitalsFormat.memoryMB(hw.gpuInUseMB), color: .indigo)
                    statBox(title: ZtatL10n.tr("已分配显存", "Allocated"), value: VitalsFormat.memoryMB(hw.gpuAllocatedMB), color: .purple)
                    let capGB = hw.gpuWiredLimitMB > 0 ? hw.gpuWiredLimitMB / 1024.0 : hw.gpuRecommendedMaxVRAMGB
                    statBox(title: ZtatL10n.tr("Metal 建议上限", "Metal Max"), value: String(format: "%.1f GB", capGB), color: .secondary)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            if hw.aneSupported, let onSelectPane {
                Button {
                    onSelectPane(.ane)
                } label: {
                    HStack {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.pink)
                        Text(ZtatL10n.tr("神经网络引擎 (ANE)", "Apple Neural Engine"))
                            .font(.system(size: 11.5, weight: .bold))
                        Spacer()
                        Text(String(format: "%.1fW · %.0f%%", hw.powerRails.aneWatts, hw.aneUtilization * 100))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.pink)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.pink.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func metricBar(label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            }
            ProgressView(value: min(1.0, max(0.0, value))).tint(color)
        }
    }

    private func statBox(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 3. Neural Engine (ANE) Detail Pane

public struct VitalsANEPaneView: View {
    @ObservedObject public var model: VitalsDashboardModel
    private var hw: VitalsHardwareSnapshot { model.hardware }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ZtatL10n.tr("Apple 神经网络引擎 (ANE)", "Apple Neural Engine (ANE)"))
                            .font(.system(size: 13, weight: .bold))
                        Text(ZtatL10n.tr("通过 IOReport Energy Model 实时采集推理功耗与负载", "Live inference power & utilization via IOReport Energy Model"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.2f W", hw.powerRails.aneWatts))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.pink)
                }

                VitalsSparkline(values: model.aneHistory, color: .pink, fixedMax: 1.0)
                    .frame(height: 54)

                HStack {
                    Text(String(format: ZtatL10n.tr("估算负载 %.0f%%", "Estimated Load %.0f%%"), hw.aneUtilization * 100))
                    Spacer()
                    Text(String(format: ZtatL10n.tr("平台峰值参考 %.1f W", "Platform Peak Ref %.1f W"), hw.aneMaxPowerWatts))
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            // SoC Power Distribution Comparison
            VStack(alignment: .leading, spacing: 8) {
                Text(ZtatL10n.tr("Apple Silicon 芯片各单元实时功耗", "Apple Silicon Power Distribution"))
                    .font(.system(size: 11.5, weight: .bold))
                let maxRail = max(hw.powerRails.cpuWatts, hw.powerRails.gpuWatts, hw.powerRails.aneWatts, hw.powerRails.dramWatts, 1.0)
                railRow("CPU", watts: hw.powerRails.cpuWatts, maxW: maxRail, color: .blue)
                railRow("GPU", watts: hw.powerRails.gpuWatts, maxW: maxRail, color: .indigo)
                railRow("ANE", watts: hw.powerRails.aneWatts, maxW: maxRail, color: .pink)
                railRow("DRAM", watts: hw.powerRails.dramWatts, maxW: maxRail, color: .green)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }

    private func railRow(_ label: String, watts: Double, maxW: Double, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .frame(width: 44, alignment: .leading)
            ProgressView(value: min(1.0, max(0.0, watts / maxW))).tint(color)
            Text(String(format: "%.2f W", watts))
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
        }
    }
}

// MARK: - 4. Memory Detail Pane

public struct VitalsMemoryPaneView: View {
    @ObservedObject public var model: VitalsDashboardModel
    private var mem: VitalsMemoryPressure { model.hardware.memory }

    private var pressureColor: Color {
        switch mem.level {
        case .critical: return .red
        case .warning: return .orange
        case .normal: return .green
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ZtatL10n.tr("物理内存与内核压力", "Physical Memory & Kernel Pressure"))
                            .font(.system(size: 12.5, weight: .bold))
                        Text(ZtatL10n.tr("内存压力状态：\(mem.level.label)", "Pressure Level: \(mem.level.label)"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(pressureColor)
                    }
                    Spacer()
                    Text(String(format: "%.1f / %.0f GB", mem.usedGB, mem.totalGB))
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(pressureColor)
                }

                // Segmented proportional memory composition bar (accounts for HStack spacing & clamps <= 1.0)
                GeometryReader { geo in
                    let total = max(mem.totalGB, 0.001)
                    let usableW = max(0, geo.size.width - 4)
                    let appRatio = min(1.0, max(0, mem.appGB / total))
                    let wiredRatio = min(max(0, 1.0 - appRatio), max(0, mem.wiredGB / total))
                    let compRatio = min(max(0, 1.0 - appRatio - wiredRatio), max(0, mem.compressedGB / total))
                    let cacheRatio = min(max(0, 1.0 - appRatio - wiredRatio - compRatio), max(0, min(mem.cachedGB, mem.freeGB) / total))
                    HStack(spacing: 1) {
                        Rectangle().fill(Color.blue).frame(width: usableW * CGFloat(appRatio))
                        Rectangle().fill(Color.orange).frame(width: usableW * CGFloat(wiredRatio))
                        Rectangle().fill(Color.purple).frame(width: usableW * CGFloat(compRatio))
                        Rectangle().fill(Color.teal.opacity(0.6)).frame(width: usableW * CGFloat(cacheRatio))
                        Rectangle().fill(Color.primary.opacity(0.08))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)

                VitalsSparkline(values: model.memHistory, color: pressureColor, fixedMax: 1.0)
                    .frame(height: 44)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            // Detailed Memory Breakdown
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                memCell(ZtatL10n.tr("App 内存", "App Memory"), String(format: "%.2f GB", mem.appGB), .blue)
                memCell(ZtatL10n.tr("联动 (Wired)", "Wired"), String(format: "%.2f GB", mem.wiredGB), .orange)
                memCell(ZtatL10n.tr("已压缩", "Compressed"), String(format: "%.2f GB", mem.compressedGB), .purple)
                memCell(ZtatL10n.tr("已缓存文件", "Cached Files"), String(format: "%.2f GB", mem.cachedGB), .teal)
                memCell(ZtatL10n.tr("已使用交换", "Swap Used"), String(format: "%.2f GB", mem.swapUsedGB), mem.swapUsedGB > 2 ? .orange : .secondary)
                memCell(ZtatL10n.tr("换入 / 换出", "Page In/Out"), "\(mem.pageIns / 1000)k / \(mem.pageOuts / 1000)k", .secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            // Top Memory Apps
            VStack(alignment: .leading, spacing: 6) {
                Text(ZtatL10n.tr("物理内存占用最高的应用", "Top Memory Consumers (App Grouped)"))
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.secondary)

                ForEach(model.appGroups.sorted { $0.totalMemoryMB > $1.totalMemoryMB }.prefix(7)) { group in
                    HStack(spacing: 8) {
                        VitalsFormat.appIcon(for: group.bundleURL)
                            .resizable().scaledToFit().frame(width: 15, height: 15)
                        Text(group.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        if group.processCount > 1 {
                            Text("(\(group.processCount))")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(VitalsFormat.memoryMB(group.totalMemoryMB))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }

    private func memCell(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value).font(.system(size: 12, weight: .bold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 5. Disk & Volumes Detail Pane

public struct VitalsDiskPaneView: View {
    @ObservedObject public var model: VitalsDashboardModel
    private var hw: VitalsHardwareSnapshot { model.hardware }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Live Disk Throughput Card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ZtatL10n.tr("实时磁盘吞吐量", "Live Disk I/O"))
                            .font(.system(size: 12.5, weight: .bold))
                        Text(String(format: "IOPS: R %.0f/s · W %.0f/s", hw.diskReadIOPS, hw.diskWriteIOPS))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "R %.1f MB/s", hw.diskReadMBs))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.purple)
                        Text(String(format: "W %.1f MB/s", hw.diskWriteMBs))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.pink)
                    }
                }
                VitalsSparkline(values: model.diskReadHistory, color: .purple, secondaryValues: model.diskWriteHistory, secondaryColor: .pink)
                    .frame(height: 46)
                HStack {
                    Text(String(format: ZtatL10n.tr("开机累计读取 %.1f GB", "Session Read %.1f GB"), hw.diskTotalReadGB))
                    Spacer()
                    Text(String(format: ZtatL10n.tr("开机累计写入 %.1f GB", "Session Written %.1f GB"), hw.diskTotalWrittenGB))
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            // Mounted Volumes with Eject & Disk Holder Scanner
            VStack(alignment: .leading, spacing: 8) {
                Text(ZtatL10n.tr("已挂载卷宗 (\(hw.diskVolumes.count))", "Mounted Volumes (\(hw.diskVolumes.count))"))
                    .font(.system(size: 11.5, weight: .bold))

                ForEach(hw.diskVolumes) { vol in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: vol.isExternal ? "externaldrive.fill" : "internaldrive.fill")
                                .foregroundStyle(vol.isExternal ? .orange : .purple)
                            Text(vol.name)
                                .font(.system(size: 11.5, weight: .bold))
                            Text(vol.fileSystem)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if vol.isEjectable {
                                Button(ZtatL10n.tr("查占用", "Holders")) {
                                    model.scanDiskHolders(for: vol)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)

                                Button(ZtatL10n.tr("推出", "Eject")) {
                                    model.ejectVolume(vol)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                        ProgressView(value: vol.usedFraction)
                            .tint(vol.usedFraction > 0.9 ? .red : .purple)
                        HStack {
                            Text(String(format: ZtatL10n.tr("已用 %.1f / %.1f GB", "%.1f / %.1f GB used"), vol.usedGB, vol.totalGB))
                            Spacer()
                            Text(String(format: ZtatL10n.tr("可用 %.1f GB", "%.1f GB free"), vol.freeGB))
                                .foregroundStyle(.green)
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    }
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            // Disk Holders Result (when scanning an external disk)
            if let target = model.diskHoldersTarget {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(ZtatL10n.tr("占用「\(target)」的文件与进程", "Open Files Holding \"\(target)\""))
                            .font(.system(size: 11, weight: .bold))
                        Spacer()
                        if model.isScanningDiskHolders {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if model.diskHolders.isEmpty && !model.isScanningDiskHolders {
                        Text(ZtatL10n.tr("没有进程占用该磁盘，可安全推出。", "No process is holding files on this volume; safe to eject."))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.green)
                    } else {
                        ForEach(model.diskHolders.prefix(8)) { h in
                            HStack(spacing: 6) {
                                Text("\(h.processName) (\(h.pid))")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text(h.path)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button(ZtatL10n.tr("退出", "Quit")) {
                                    model.terminatePID(h.pid, force: false)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
            }

            // Top Disk Writers
            VStack(alignment: .leading, spacing: 6) {
                Text(ZtatL10n.tr("磁盘写入最多的进程", "Top Disk Writers"))
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.secondary)
                ForEach(model.processes.sorted { $0.diskWriteBytes > $1.diskWriteBytes }.prefix(5)) { proc in
                    HStack {
                        Text(proc.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text("R " + VitalsFormat.bytes(proc.diskReadBytes))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        Text("W " + VitalsFormat.bytes(proc.diskWriteBytes))
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(.pink)
                            .frame(width: 72, alignment: .trailing)
                    }
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }
}

// MARK: - 6. Network & Wi-Fi Detail Pane

public struct VitalsNetworkPaneView: View {
    @ObservedObject public var model: VitalsDashboardModel
    public let onSelectPane: ((VitalsPane) -> Void)?
    private var hw: VitalsHardwareSnapshot { model.hardware }

    public init(model: VitalsDashboardModel, onSelectPane: ((VitalsPane) -> Void)? = nil) {
        self.model = model
        self.onSelectPane = onSelectPane
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(hw.activeInterfaceKind) (\(hw.activeInterfaceName))")
                            .font(.system(size: 13, weight: .bold))
                        Text(ZtatL10n.tr("本地 IP：\(hw.localIPv4)", "Local IP: \(hw.localIPv4)"))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("↓ " + VitalsFormat.speedKBs(hw.netDownloadKBs))
                            .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.teal)
                        Text("↑ " + VitalsFormat.speedKBs(hw.netUploadKBs))
                            .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.cyan)
                    }
                }

                VitalsSparkline(values: model.netDownHistory, color: .teal, secondaryValues: model.netUpHistory, secondaryColor: .cyan)
                    .frame(height: 50)

                HStack {
                    Text(String(format: ZtatL10n.tr("累计下载 %.2f GB", "Total Down %.2f GB"), hw.netTotalInMB / 1024.0))
                    Spacer()
                    Text(String(format: ZtatL10n.tr("累计上传 %.2f GB", "Total Up %.2f GB"), hw.netTotalOutMB / 1024.0))
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            // Wi-Fi Details
            if hw.wifiSSID != nil || hw.wifiRSSI != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Wi-Fi")
                        .font(.system(size: 11.5, weight: .bold))
                    HStack(spacing: 12) {
                        if let ssid = hw.wifiSSID { infoCol("SSID", ssid) }
                        if let rssi = hw.wifiRSSI { infoCol(ZtatL10n.tr("信号", "RSSI"), "\(rssi) dBm") }
                        if let tx = hw.wifiTxRateMbps { infoCol(ZtatL10n.tr("协商速率", "Tx Rate"), String(format: "%.0f Mbps", tx)) }
                        if let ch = hw.wifiChannel { infoCol(ZtatL10n.tr("信道", "Channel"), "#\(ch)") }
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
            }

            // Active Ports Summary
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(ZtatL10n.tr("本机监听端口 (\(model.listeningPorts.count))", "Listening Ports (\(model.listeningPorts.count))"))
                        .font(.system(size: 11.5, weight: .bold))
                    Spacer()
                    if let onSelectPane {
                        Button(ZtatL10n.tr("查看全部", "All Ports")) {
                            onSelectPane(.ports)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    }
                }
                ForEach(model.listeningPorts.prefix(6)) { port in
                    HStack(spacing: 6) {
                        Text(":\(port.port)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.blue)
                            .frame(width: 52, alignment: .leading)
                        Text(port.processName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        if port.isNetworkExposed {
                            Text(ZtatL10n.tr("局域网可见", "LAN"))
                                .font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.18)))
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button(ZtatL10n.tr("打开", "Open")) {
                            VitalsPopoverWindow.shared.dismiss()
                            model.openLocalPort(port.port)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }

    private func infoCol(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 7. Battery & Power Detail Pane

public struct VitalsBatteryPaneView: View {
    @ObservedObject public var model: VitalsDashboardModel
    private var hw: VitalsHardwareSnapshot { model.hardware }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hw.hasBattery ? ZtatL10n.tr("电池状态与健康", "Battery Status & Health") : ZtatL10n.tr("交流电源功耗", "AC Power Telemetry"))
                            .font(.system(size: 13, weight: .bold))
                        if let mins = hw.batteryTimeRemainingMinutes, mins > 0 {
                            Text(hw.batteryCharging
                                 ? ZtatL10n.tr("预计 \(VitalsFormat.minutes(mins)) 后充满", "Est. \(VitalsFormat.minutes(mins)) until full")
                                 : ZtatL10n.tr("预计剩余续航 \(VitalsFormat.minutes(mins))", "Est. \(VitalsFormat.minutes(mins)) remaining"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(hw.batteryExternalConnected ? ZtatL10n.tr("已连接电源适配器", "Connected to Power Adapter") : ZtatL10n.tr("正在使用电池供电", "Running on Battery"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(hw.batteryPercent.map { "\($0)%" } ?? (hw.powerRails.systemTotalWatts.map { String(format: "%.1fW", $0) } ?? "AC"))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(hw.batteryCharging ? .green : .orange)
                }

                if let pct = hw.batteryPercent {
                    ProgressView(value: Double(pct) / 100.0)
                        .tint(hw.batteryCharging ? .green : (pct < 20 ? .red : .orange))
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    cell(ZtatL10n.tr("电池健康", "Health"), hw.batteryHealthPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                    cell(ZtatL10n.tr("循环次数", "Cycles"), hw.batteryCycleCount.map { "\($0)" } ?? "—")
                    cell(ZtatL10n.tr("适配器功率", "Adapter"), hw.batteryAdapterWatts.map { "\($0) W" } ?? "—")
                    cell(ZtatL10n.tr("电池功率", "Battery W"), hw.batteryWatts.map { String(format: "%.1f W", $0) } ?? "—")
                    cell(ZtatL10n.tr("整机功耗", "System W"), hw.powerRails.systemTotalWatts.map { String(format: "%.1f W", $0) } ?? String(format: "%.1f W", hw.powerRails.packageTotalWatts))
                    cell(ZtatL10n.tr("电压 / 温度", "Volt / Temp"), "\(hw.batteryVoltageV.map { String(format: "%.2fV", $0) } ?? "—") · \(hw.batteryTempC.map { String(format: "%.0f°C", $0) } ?? "—")")
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            // Sleep Assertions ("What's Keeping Mac Awake")
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundStyle(.orange)
                    Text(ZtatL10n.tr("阻止 Mac 休眠的进程 (\(model.sleepAssertions.count))", "What's Keeping This Mac Awake (\(model.sleepAssertions.count))"))
                        .font(.system(size: 11.5, weight: .bold))
                }
                if model.sleepAssertions.isEmpty {
                    Text(ZtatL10n.tr("当前无活跃的防休眠断言。", "No active sleep-preventing assertions."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.sleepAssertions.prefix(6)) { a in
                        HStack(spacing: 6) {
                            Text(a.processName)
                                .font(.system(size: 11, weight: .semibold))
                            Text("PID \(a.pid)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text(a.reason)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            // Top Energy Consumers
            VStack(alignment: .leading, spacing: 6) {
                Text(ZtatL10n.tr("能耗影响最高的应用", "Top Energy Impact Apps"))
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.secondary)
                ForEach(model.appGroups.sorted { $0.totalEnergyImpact > $1.totalEnergyImpact }.prefix(5)) { group in
                    HStack {
                        VitalsFormat.appIcon(for: group.bundleURL)
                            .resizable().scaledToFit().frame(width: 15, height: 15)
                        Text(group.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f", group.totalEnergyImpact))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11.5, weight: .bold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 8. Fans, Thermals & Real SMC Sensors Detail Pane

public struct VitalsFansPaneView: View {
    @ObservedObject public var model: VitalsDashboardModel
    private var hw: VitalsHardwareSnapshot { model.hardware }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Fans Card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "fanblades.fill")
                        .foregroundStyle(.cyan)
                    Text(ZtatL10n.tr("风扇实时转速 (SMC)", "Fan Speeds (SMC)"))
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text(thermalTitle)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(thermalColor)
                }

                if hw.fans.isEmpty {
                    Text(ZtatL10n.tr("此设备未检测到独立可控风扇（如 MacBook Air 无风扇架构）。", "No active hardware fans detected (fanless Mac)."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hw.fans) { fan in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(fan.name)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(fan.isAutomatic ? ZtatL10n.tr("自动", "Auto") : ZtatL10n.tr("手动", "Manual"))
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                                Spacer()
                                Text("\(Int(fan.currentRPM.rounded())) RPM")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.cyan)
                                Text("/ \(Int(fan.maxRPM.rounded()))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: fan.fraction)
                                .tint(fan.fraction > 0.75 ? .orange : .cyan)
                        }
                    }
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            // Real SMC / HID Temperature Sensors
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(.orange)
                    Text(ZtatL10n.tr("硬件温度传感器 (\(hw.temperatureSensors.count))", "Temperature Sensors (\(hw.temperatureSensors.count))"))
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    if let hot = hw.hottestTempC {
                        Text(String(format: ZtatL10n.tr("最高 %.1f°C", "Peak %.1f°C"), hot))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(hot > 80 ? .red : .orange)
                    }
                }

                if hw.temperatureSensors.isEmpty {
                    Text(model.processes.isEmpty
                        ? ZtatL10n.tr("正在读取 SMC / HID 温度传感器…", "Reading SMC / HID temperature sensors…")
                        : ZtatL10n.tr("当前设备未暴露可读的 SMC / HID 温度传感器。", "No readable SMC / HID temperature sensors exposed on this Mac."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hw.temperatureSensors.prefix(16)) { sensor in
                        HStack(spacing: 8) {
                            Text(sensor.group.title)
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 38, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(sensor.name)
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            ProgressView(value: min(1.0, max(0.0, (sensor.celsius - 20.0) / 85.0)))
                                .tint(tempColor(sensor.celsius))
                                .frame(width: 72)
                            Text(String(format: "%.1f°C", sensor.celsius))
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(tempColor(sensor.celsius))
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }

    private func tempColor(_ c: Double) -> Color {
        if c >= 85 { return .red }
        if c >= 68 { return .orange }
        if c >= 50 { return .yellow }
        return .green
    }

    private var thermalTitle: String {
        switch hw.thermalState {
        case .nominal: return ZtatL10n.tr("正常", "Nominal")
        case .fair: return ZtatL10n.tr("温热", "Fair")
        case .serious: return ZtatL10n.tr("偏热", "Serious")
        case .critical: return ZtatL10n.tr("过热降频", "Critical")
        @unknown default: return "—"
        }
    }

    private var thermalColor: Color {
        switch hw.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }
}

// MARK: - 9. Bluetooth Devices Detail Pane

public struct VitalsBluetoothPaneView: View {
    @ObservedObject public var model: VitalsDashboardModel
    private var devices: [VitalsBluetoothDevice] { model.hardware.bluetoothDevices }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.indigo)
                Text(ZtatL10n.tr("已连接蓝牙设备 (\(devices.count))", "Connected Bluetooth Devices (\(devices.count))"))
                    .font(.system(size: 12.5, weight: .bold))
                Spacer()
                Button(ZtatL10n.tr("蓝牙设置…", "Bluetooth Settings…")) {
                    VitalsPopoverWindow.shared.dismiss()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            if devices.isEmpty {
                Text(ZtatL10n.tr("当前没有已连接的蓝牙外设。", "No connected Bluetooth devices right now."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            } else {
                ForEach(devices) { dev in
                    HStack(spacing: 10) {
                        Image(systemName: dev.symbolName)
                            .font(.system(size: 15))
                            .foregroundStyle(.indigo)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dev.name).font(.system(size: 12, weight: .semibold))
                            HStack(spacing: 6) {
                                Text(dev.category)
                                if let rssi = dev.rssi { Text("RSSI \(rssi) dBm") }
                            }
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let bat = dev.batteryPercent {
                            HStack(spacing: 4) {
                                Image(systemName: bat < 20 ? "battery.25" : "battery.100")
                                    .foregroundStyle(bat < 20 ? .red : .green)
                                Text("\(bat)%")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                            }
                        } else {
                            Text(ZtatL10n.tr("已连接", "Connected"))
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
                }
            }
        }
    }
}

// MARK: - 10. Sound & Output Audio Detail Pane

public struct VitalsSoundPaneView: View {
    @ObservedObject public var model: VitalsDashboardModel
    private var hw: VitalsHardwareSnapshot { model.hardware }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button {
                        model.toggleSystemMute()
                    } label: {
                        Image(systemName: hw.isSystemMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(hw.isSystemMuted ? .red : .pink)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(ZtatL10n.tr("系统主音量", "System Output Volume"))
                            .font(.system(size: 12, weight: .bold))
                        Text(hw.activeOutputAudioName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(hw.isSystemMuted ? ZtatL10n.tr("已静音", "Muted") : "\(Int((hw.systemVolume * 100).rounded()))%")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                }

                Slider(
                    value: Binding(
                        get: { Double(hw.systemVolume) },
                        set: { model.setSystemVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .tint(.pink)

                HStack {
                    Image(systemName: "mic.fill").foregroundStyle(.secondary)
                    Text(ZtatL10n.tr("当前输入设备：\(hw.activeInputAudioName)", "Input: \(hw.activeInputAudioName)"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            // Output Device Switcher
            VStack(alignment: .leading, spacing: 6) {
                Text(ZtatL10n.tr("音频输出设备切换", "Output Devices"))
                    .font(.system(size: 11.5, weight: .bold))
                ForEach(hw.outputAudioDevices) { dev in
                    Button {
                        model.selectOutputAudioDevice(dev.id)
                    } label: {
                        HStack {
                            Image(systemName: dev.isDefault ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(dev.isDefault ? Color.accentColor : .secondary)
                            Text(dev.name)
                                .font(.system(size: 11.5, weight: dev.isDefault ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }
}

// MARK: - 11. AI Coding Agents Detail Pane

public struct VitalsAgentsPaneView: View {
    @ObservedObject public var model: VitalsDashboardModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.orange)
                Text(ZtatL10n.tr("活跃 AI 编程智能体 (\(model.agentSessions.count))", "Active AI Coding Agents (\(model.agentSessions.count))"))
                    .font(.system(size: 12.5, weight: .bold))
                Spacer()
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            if model.agentSessions.isEmpty {
                Text(ZtatL10n.tr("未检测到运行中的 AI 智能体（支持 Antigravity、Claude Code、Codex、Cursor、Ollama、Gemini CLI 等）。",
                                "No active AI coding agents detected (supports Antigravity, Claude Code, Codex, Cursor, Ollama, Gemini CLI)."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            } else {
                ForEach(model.agentSessions) { agent in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(agent.isIdle ? Color.secondary.opacity(0.5) : Color.green)
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(agent.name).font(.system(size: 12, weight: .bold))
                                Text("PID \(agent.pid)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                if let port = agent.activePorts.first {
                                    Text(":\(port)")
                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.blue)
                                }
                            }
                            if let cwd = agent.workingDir {
                                Text(cwd)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(String(format: "%.1f%% CPU", agent.cpuPercent))
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.blue)
                            Text(VitalsFormat.memoryMB(agent.memoryMB))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            model.terminatePID(agent.pid, force: false)
                        } label: {
                            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(ZtatL10n.tr("结束智能体会话", "Stop Agent Session"))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
                }
            }
        }
    }
}

// MARK: - 12. Containers Detail Pane (Docker / OrbStack / Colima)

public struct VitalsContainersPaneView: View {
    @ObservedObject public var model: VitalsDashboardModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "shippingbox.fill").foregroundStyle(.cyan)
                Text(ZtatL10n.tr("运行中容器 (\(model.containers.count))", "Running Containers (\(model.containers.count))"))
                    .font(.system(size: 12.5, weight: .bold))
                Spacer()
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            if model.containers.isEmpty {
                Text(ZtatL10n.tr("当前没有运行中的 Docker / OrbStack / Colima 容器。", "No running Docker / OrbStack / Colima containers."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            } else {
                ForEach(model.containers) { c in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(c.name).font(.system(size: 12, weight: .bold))
                            Text(c.engine)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.cyan.opacity(0.16)))
                                .foregroundStyle(.cyan)
                            Spacer()
                            Text(String(format: "%.1f%% · %@", c.cpuPercent, c.memoryText))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text("\(c.image) · \(c.status)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack {
                            if !c.ports.isEmpty {
                                Text(c.ports)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.blue)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(ZtatL10n.tr("重启", "Restart")) {
                                model.controlContainer(c, action: "restart")
                            }
                            .buttonStyle(.bordered).controlSize(.mini)
                            Button(ZtatL10n.tr("停止", "Stop")) {
                                model.controlContainer(c, action: "stop")
                            }
                            .buttonStyle(.bordered).controlSize(.mini).tint(.red)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
                }
            }
        }
    }
}

// MARK: - 13. Listening Ports Detail Pane

public struct VitalsPortsPaneView: View {
    @ObservedObject public var model: VitalsDashboardModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "network").foregroundStyle(.blue)
                Text(ZtatL10n.tr("本地开放监听端口 (\(model.listeningPorts.count))", "Listening TCP Ports (\(model.listeningPorts.count))"))
                    .font(.system(size: 12.5, weight: .bold))
                Spacer()
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))

            if model.listeningPorts.isEmpty {
                Text(ZtatL10n.tr("暂无正在监听的 TCP 端口。", "No listening TCP ports found."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(model.listeningPorts) { port in
                    HStack(spacing: 8) {
                        Text(":\(port.port)")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.blue)
                            .frame(width: 54, alignment: .leading)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(port.processName)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1)
                                Text(port.category.rawValue)
                                    .font(.system(size: 8.5, weight: .bold))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                                if port.isNetworkExposed {
                                    Text(ZtatL10n.tr("局域网", "LAN"))
                                        .font(.system(size: 8.5, weight: .bold))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text("PID \(port.pid) · \(port.address)" + (port.workingDir.map { " · \(($0 as NSString).lastPathComponent)" } ?? ""))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            VitalsPopoverWindow.shared.dismiss()
                            model.openLocalPort(port.port)
                        } label: {
                            Image(systemName: "safari").font(.system(size: 11.5))
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .help(ZtatL10n.tr("在浏览器中打开 localhost:\(port.port)", "Open http://localhost:\(port.port)"))

                        Button {
                            model.terminatePID(port.pid, force: false)
                        } label: {
                            Image(systemName: "xmark.circle").font(.system(size: 11.5)).foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help(ZtatL10n.tr("结束监听进程", "Stop Process"))
                    }
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.045)))
                }
            }
        }
    }
}
