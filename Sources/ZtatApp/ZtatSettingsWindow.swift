// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import ZtatCore
import ZtatPowerGuard
import ZtatStatsHost
import StatusTrioCore
import VorssaintToolbox

@MainActor
final class ZtatSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = ZtatSettingsWindowController()

    private var window: NSWindow?
    private let state = ZtatSettingsWindowState()

    func show(section: ZtatSettingsSection = .general) {
        state.selection = section

        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ZtatUnifiedSettingsView(state: state)
        let hosting = NSHostingController(rootView: rootView)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = ZtatL10n.tr("ztat 统一设置", "ztat Unified Settings")
        win.contentViewController = hosting
        win.minSize = NSSize(width: 760, height: 520)
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.toolbarStyle = .unified
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func windowWillClose(_ notification: Notification) {
        // Keep window controller lightweight while preserving quick reopen
    }
}

@MainActor
private final class ZtatSettingsWindowState: ObservableObject {
    @Published var selection: ZtatSettingsSection = .general
}

private struct ZtatUnifiedSettingsView: View {
    @ObservedObject var state: ZtatSettingsWindowState

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<ZtatSettingsSection?>(
                get: { state.selection },
                set: { if let v = $0 { state.selection = v } }
            )) {
                ForEach(ZtatSettingsSection.allCases) { section in
                    Label(title(for: section), systemImage: symbol(for: section))
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 175, ideal: 195, max: 230)
        } detail: {
            detailView(for: state.selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func detailView(for section: ZtatSettingsSection) -> some View {
        switch section {
        case .general:
            ZtatGeneralSettingsView(onNavigate: { state.selection = $0 })
        case .statusTrio:
            ZtatStatusTrioHost.shared.makeSettingsView()
        case .powerGuard:
            PowerGuardSettingsView()
        case .stats:
            StatsSettingsContainerView()
        case .toolbox:
            ZtatVorssaintHost.shared.makeSettingsView()
        }
    }

    private func title(for section: ZtatSettingsSection) -> String {
        switch section {
        case .general: return ZtatL10n.tr("通用与菜单栏", "General & Menu Bar")
        case .statusTrio: return ZtatL10n.tr("统一状态图标", "Status Icon & Panel")
        case .powerGuard: return ZtatL10n.tr("保活与熄屏", "PowerGuard & Blackout")
        case .stats: return ZtatL10n.tr("性能监控指标", "Hardware Stats")
        case .toolbox: return ZtatL10n.tr("系统工具箱", "Utility Toolbox")
        }
    }

    private func symbol(for section: ZtatSettingsSection) -> String {
        switch section {
        case .general: return "slider.horizontal.3"
        case .statusTrio: return "dot.radiowaves.left.and.right"
        case .powerGuard: return "bolt.shield.fill"
        case .stats: return "gauge.with.dots.needle.67percent"
        case .toolbox: return "square.grid.2x2.fill"
        }
    }
}

private struct ZtatGeneralSettingsView: View {
    let onNavigate: (ZtatSettingsSection) -> Void
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

            Section(ZtatL10n.tr("菜单栏极简契约", "Clean Menu Bar Contract")) {
                LabeledContent(
                    ZtatL10n.tr("唯一主菜单栏图标", "Primary Menu Bar Icon"),
                    value: ZtatL10n.tr("Status Trio 自适应三合一图标（点击展开统一控制中心）", "Status Trio adaptive icon (opens unified Hub)")
                )
                LabeledContent(
                    ZtatL10n.tr("独立性能监控指标", "Dedicated Performance Metrics"),
                    value: statsHost.enabledModuleCount == 0
                        ? ZtatL10n.tr("当前未开启（点击下方进入配置）", "None active (enable metrics in Hardware Stats)")
                        : ZtatL10n.tr("已开启 \(statsHost.enabledModuleCount) 项 Stats 指标", "\(statsHost.enabledModuleCount) Stats metric(s) active")
                )
                LabeledContent(
                    ZtatL10n.tr("保活与工具箱图标", "PowerGuard & Toolbox Icons"),
                    value: ZtatL10n.tr("已收敛至统一控制中心，不占菜单栏空间", "Embedded in Unified Hub (zero extra menu bar icons)")
                )
            }

            Section(ZtatL10n.tr("快速跳转", "Quick Navigation")) {
                HStack(spacing: 10) {
                    Button(ZtatL10n.tr("配置状态图标", "Status Icon")) { onNavigate(.statusTrio) }
                    Button(ZtatL10n.tr("保活与熄屏 (\(powerGuard.currentSnapshot.summaryLabel))", "PowerGuard")) { onNavigate(.powerGuard) }
                    Button(ZtatL10n.tr("选择监控指标", "Hardware Stats")) { onNavigate(.stats) }
                    Button(ZtatL10n.tr("管理系统工具箱", "Utility Toolbox")) { onNavigate(.toolbox) }
                }
            }

            Section(ZtatL10n.tr("开源许可与架构", "License & Architecture")) {
                Text(ZtatL10n.tr(
                    "ztat 遵循 GPL-3.0-or-later 许可发布。已移除各上游重叠功能、后台遥测与重复轮询，并针对 Apple Silicon 与 macOS Liquid Glass 进行性能调优。",
                    "ztat is licensed under GPL-3.0-or-later. Overlapping modules, upstream telemetry, and duplicate polling loops have been eliminated and optimized for Apple Silicon."
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
