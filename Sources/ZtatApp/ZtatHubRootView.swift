// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import ZtatCore
import ZtatPowerGuard
import ZtatStatsHost
import VorssaintToolbox

extension Notification.Name {
    static let ztatHubPanelVisibilityDidChange = Notification.Name("dev.ztat.hubPanelVisibilityDidChange")
}

/// Unified 356pt Liquid Glass Hub root view hosted inside Status Trio's AnchoredStatusPanel.
/// Combines:
///  1. 状态 (Status Trio — Wi-Fi, Battery, Bluetooth/ANC, Audio, Input, DDC Display)
///  2. 保活 (ZtatPowerGuard — Remote-Ready, Clamshell Lock, 0% Physical Blackout, Live Telemetry)
///  3. 工具箱 (ZtatVorssaint — Per-App Volume Mixer >100%, Quick Tools, Clipboard, XDR, Island)
///  4. 监控 (ZtatStats — 9 Hardware Metrics menu bar controls & Stats configuration)
struct ZtatHubRootView: View {
    let statusTrioBody: AnyView
    let onOpenSettings: (ZtatSettingsSection) -> Void

    @State private var selectedTab: ZtatHubTab = .status
    @ObservedObject private var powerGuard = PowerGuardCoordinator.shared
    @ObservedObject private var statsHost = ZtatStatsHost.shared

    var body: some View {
        VStack(spacing: 8) {
            headerBar
            tabStrip
            Divider().opacity(0.28)
            tabContent
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .top)
        .onReceive(NotificationCenter.default.publisher(for: .ztatOpenHubTab)) { note in
            if let raw = note.object as? String, let tab = ZtatHubTab(rawValue: raw) {
                selectedTab = tab
            } else if let tab = note.object as? ZtatHubTab {
                selectedTab = tab
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ztatHubPanelVisibilityDidChange)) { note in
            let isVisible = (note.object as? Bool) ?? false
            powerGuard.setPanelVisible(isVisible && selectedTab == .powerGuard)
        }
    }

    // MARK: - Top Brand + Live PowerGuard Pill + Settings Gear + Quick Menu

    private var headerBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(ZtatBrand.appName)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .tracking(0.3)
            }

            Spacer(minLength: 4)

            // Live clickable PowerGuard status pill (surfaces remote-ready keep-awake right in the header)
            Button {
                if selectedTab == .powerGuard {
                    powerGuard.toggleRemoteReadyMode()
                } else {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        selectedTab = .powerGuard
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(powerGuardPillColor)
                        .frame(width: 6, height: 6)
                    Text(powerGuardPillText)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .foregroundStyle(powerGuard.isAnyGuardActive ? powerGuardPillColor : .secondary)
                .background(
                    Capsule(style: .continuous)
                        .fill(powerGuard.isAnyGuardActive ? powerGuardPillColor.opacity(0.14) : Color.primary.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .help(ZtatL10n.tr("保活与熄屏状态（点击切换保活页，再次点击开关保活）", "Keep-awake & blackout status (click for Guard tab)"))

            Button {
                onOpenSettings(settingsSection(for: selectedTab))
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help(ZtatL10n.tr("打开 ztat 统一设置 (⌘,)", "Open ztat Unified Settings (⌘,)"))

            Menu {
                Button(ZtatL10n.tr("打开统一设置...", "Unified Settings...")) {
                    onOpenSettings(settingsSection(for: selectedTab))
                }
                Button(ZtatL10n.tr("本机硬件概览...", "Hardware Dashboard...")) {
                    statsHost.openNativeStatsSettings(selecting: "dashboard")
                }
                Divider()
                Button(powerGuard.isAnyGuardActive
                       ? ZtatL10n.tr("停止所有保活守护", "Disable Keep-Awake Guard")
                       : ZtatL10n.tr("一键合盖+远程保活", "Enable Remote-Ready Guard")) {
                    powerGuard.toggleRemoteReadyMode()
                }
                Button(powerGuard.isBlackoutActive
                       ? ZtatL10n.tr("恢复内建屏幕亮度", "Restore Display Brightness")
                       : ZtatL10n.tr("开启物理熄屏 0% (⌘⌥B 恢复)", "Enable 0% Physical Blackout")) {
                    powerGuard.toggleBlackoutMode()
                }
                Divider()
                Button(ZtatL10n.tr("退出 ztat", "Quit ztat")) {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
            .help(ZtatL10n.tr("更多操作", "More actions"))
        }
    }

    private var powerGuardPillColor: Color {
        if powerGuard.isBlackoutActive { return .indigo }
        if powerGuard.isClamshellLocked { return .orange }
        if powerGuard.isIdleKeepAwakeActive { return .green }
        return .secondary
    }

    private var powerGuardPillText: String {
        if powerGuard.isBlackoutActive { return ZtatL10n.tr("熄屏 0%", "Blackout") }
        if powerGuard.isClamshellLocked { return ZtatL10n.tr("合盖保活", "Clamshell") }
        if powerGuard.isIdleKeepAwakeActive { return ZtatL10n.tr("保活中", "Awake") }
        return ZtatL10n.tr("默认休眠", "Sleep OK")
    }

    // MARK: - 4-Tab Segmented Bar

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(Array(ZtatHubTab.allCases.enumerated()), id: \.element.id) { idx, tab in
                let isSelected = (selectedTab == tab)
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        if tab == .monitor && statsHost.enabledModuleCount > 0 {
                            Text("\(statsHost.enabledModuleCount)")
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 4)
                                .padding(.vertical, 0.5)
                                .background(
                                    Capsule().fill(isSelected ? Color.white.opacity(0.24) : Color.accentColor.opacity(0.18))
                                )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5.5)
                    .foregroundStyle(isSelected ? .white : .primary.opacity(0.85))
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.055))
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
            }
        }
    }

    // MARK: - Active Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .status:
            statusTrioBody
        case .powerGuard:
            PowerGuardPanelView(coordinator: powerGuard)
        case .toolbox:
            ZtatVorssaintHost.shared.makeToolboxPanelView {
                onOpenSettings(.toolbox)
            }
        case .monitor:
            StatsHubControlView(host: statsHost) {
                onOpenSettings(.stats)
            }
        }
    }

    private func settingsSection(for tab: ZtatHubTab) -> ZtatSettingsSection {
        switch tab {
        case .status: return .statusTrio
        case .powerGuard: return .powerGuard
        case .toolbox: return .toolbox
        case .monitor: return .stats
        }
    }
}
