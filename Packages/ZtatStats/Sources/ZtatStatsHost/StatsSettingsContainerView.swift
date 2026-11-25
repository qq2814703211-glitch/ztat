// SPDX-License-Identifier: GPL-3.0-or-later
//
//  StatsSettingsContainerView.swift
//  ZtatStatsHost
//
//  ZTAT-PATCH: Native SwiftUI overview + embedded Stats module/dashboard/settings host
//  inside ztat's single Unified Settings window (eliminates standalone Stats SettingsWindow).
//

import AppKit
import StatsKit
import SwiftUI
import ZtatCore

/// Overview & global toggles view hosted inside ztat's unified Settings window ("性能监控 → 总览与开关").
@MainActor
public struct StatsSettingsContainerView: View {
    @ObservedObject private var host: ZtatStatsHost
    private let onSelectTarget: ((String) -> Void)?
    @State private var temperatureUnit: String
    @State private var keepMenuBarPosition: Bool
    @State private var showResetConfirmation: Bool = false

    public init(host: ZtatStatsHost, onSelectTarget: ((String) -> Void)? = nil) {
        self.host = host
        self.onSelectTarget = onSelectTarget
        _temperatureUnit = State(initialValue: Store.shared.string(key: "temperature_units", defaultValue: "system"))
        _keepMenuBarPosition = State(initialValue: Store.shared.bool(key: "keep_menubar_positions", defaultValue: false))
    }

    public init(onSelectTarget: ((String) -> Void)? = nil) {
        self.init(host: .shared, onSelectTarget: onSelectTarget)
    }

    private func navigate(to target: String) {
        if let onSelectTarget {
            onSelectTarget(target)
        } else {
            self.host.openNativeStatsSettings(selecting: target)
        }
    }

    public var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ZtatL10n.tr("硬件与系统监控", "Hardware & System Monitoring"))
                            .font(.headline)
                        Text(
                            self.host.enabledModuleCount == 0
                                ? ZtatL10n.tr("当前未启用任何菜单栏监控项（零后台采集与零占用）", "No menu bar monitors enabled (zero background polling)")
                                : ZtatL10n.tr("已启用 \(self.host.enabledModuleCount) 个菜单栏监控模块", "\(self.host.enabledModuleCount) menu bar monitor(s) active")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(ZtatL10n.tr("设备概览", "Dashboard")) {
                        self.navigate(to: "dashboard")
                    }
                    .controlSize(.regular)

                    Button(ZtatL10n.tr("全局与压测", "Global & Stress")) {
                        self.navigate(to: "settings")
                    }
                    .controlSize(.regular)
                }
            }

            Section(ZtatL10n.tr("菜单栏模块（点击“配置”在当前窗口展开详细样式）", "Menu Bar Modules")) {
                ForEach(self.host.moduleSummaries) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.symbolName)
                            .frame(width: 20)
                            .foregroundStyle(item.isEnabled ? Color.accentColor : Color.secondary)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayName)
                                .foregroundStyle(item.isAvailable ? .primary : .tertiary)
                            Text(item.liveBadge)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(ZtatL10n.tr("配置", "Configure")) {
                            self.navigate(to: item.id)
                        }
                        .controlSize(.small)
                        .disabled(!item.isAvailable)

                        Toggle("", isOn: Binding(
                            get: { item.isEnabled },
                            set: { newValue in
                                self.host.setModuleEnabled(item.id, enabled: newValue)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!item.isAvailable)
                    }
                }
            }

            Section(ZtatL10n.tr("布局与显示", "Layout & Display")) {
                Toggle(
                    ZtatL10n.tr("合并为单个菜单栏项 (Combine modules)", "Combine modules into a single menu bar item"),
                    isOn: Binding(
                        get: { self.host.isCombinedModulesEnabled },
                        set: { newValue in
                            self.host.setCombinedModulesEnabled(newValue)
                        }
                    )
                )

                Toggle(
                    ZtatL10n.tr("保留菜单栏图标位置", "Keep menu bar item positions"),
                    isOn: Binding(
                        get: { self.keepMenuBarPosition },
                        set: { newValue in
                            self.keepMenuBarPosition = newValue
                            Store.shared.set(key: "keep_menubar_positions", value: newValue)
                        }
                    )
                )

                Picker(ZtatL10n.tr("温度单位", "Temperature unit"), selection: Binding(
                    get: { self.temperatureUnit },
                    set: { newValue in
                        self.temperatureUnit = newValue
                        Store.shared.set(key: "temperature_units", value: newValue)
                    }
                )) {
                    Text(ZtatL10n.tr("跟随系统", "System")).tag("system")
                    Text("°C (" + ZtatL10n.tr("摄氏度", "Celsius") + ")").tag("celsius")
                    Text("°F (" + ZtatL10n.tr("华氏度", "Fahrenheit") + ")").tag("fahrenheit")
                }
            }

            Section(ZtatL10n.tr("维护", "Maintenance")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ZtatL10n.tr("重置性能监控偏好", "Reset Stats Preferences"))
                        Text(ZtatL10n.tr("仅清空性能监控模块的配置，不影响 ztat 其余功能设置。", "Clears only Stats module preferences without affecting other ztat settings."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(ZtatL10n.tr("重置", "Reset"), role: .destructive) {
                        self.showResetConfirmation = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            self.host.refreshSummaries()
            self.temperatureUnit = Store.shared.string(key: "temperature_units", defaultValue: "system")
            self.keepMenuBarPosition = Store.shared.bool(key: "keep_menubar_positions", defaultValue: false)
        }
        .alert(
            ZtatL10n.tr("确认重置性能监控设置？", "Reset Stats Preferences?"),
            isPresented: self.$showResetConfirmation
        ) {
            Button(ZtatL10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(ZtatL10n.tr("重置", "Reset"), role: .destructive) {
                self.host.resetAllStatsPreferences()
                self.temperatureUnit = Store.shared.string(key: "temperature_units", defaultValue: "system")
                self.keepMenuBarPosition = Store.shared.bool(key: "keep_menubar_positions", defaultValue: false)
            }
        } message: {
            Text(ZtatL10n.tr("这将关闭所有菜单栏监控项并恢复性能监控默认设置。", "All menu bar monitors will be disabled and Stats settings will be restored to defaults."))
        }
    }
}

/// Seamless embedded Stats detail pane (module settings, hardware dashboard, or global/stress settings)
/// rendered directly inside ztat's single Unified Settings window with a cohesive ztat header bar.
@MainActor
public struct StatsEmbeddedTargetView: View {
    public let target: String
    @ObservedObject private var host: ZtatStatsHost
    @State private var isPreviewActive: Bool = false

    public init(target: String, host: ZtatStatsHost) {
        self.target = target
        self.host = host
    }

    public init(target: String) {
        self.init(target: target, host: .shared)
    }

    private var summary: StatsModuleSummary? {
        self.host.moduleSummary(for: self.target)
    }

    private var headerTitle: String {
        if let summary { return summary.displayName }
        switch ZtatStatsHost.normalizeSettingsTarget(self.target) {
        case "dashboard": return ZtatL10n.tr("设备与硬件概览", "Hardware Dashboard")
        case "settings": return ZtatL10n.tr("监控全局与压力测试", "Monitor Settings & Stress Tests")
        default: return self.target
        }
    }

    private var headerSymbol: String {
        if let summary { return summary.symbolName }
        switch ZtatStatsHost.normalizeSettingsTarget(self.target) {
        case "dashboard": return "desktopcomputer"
        case "settings": return "slider.horizontal.3"
        default: return "gauge.with.dots.needle.67percent"
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: self.headerSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(self.headerTitle)
                        .font(.headline)
                    if let summary {
                        Text(summary.liveBadge)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if ZtatStatsHost.normalizeSettingsTarget(self.target) == "dashboard" {
                        Text(ZtatL10n.tr("实时硬件规格与运行时间", "Live hardware specifications & uptime"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(ZtatL10n.tr("合并显示策略、配置导入导出与 Apple Silicon 压测", "Combined bar rules, export/import & Apple Silicon stress tests"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let summary {
                    if self.host.moduleHasPreview(summary.id) {
                        Button {
                            let next = !self.isPreviewActive
                            self.isPreviewActive = next
                            self.host.setModulePreview(summary.id, visible: next)
                        } label: {
                            Label(
                                self.isPreviewActive
                                    ? ZtatL10n.tr("返回设置", "Settings")
                                    : ZtatL10n.tr("实时预览", "Live Preview"),
                                systemImage: self.isPreviewActive ? "slider.horizontal.3" : "eye"
                            )
                        }
                        .controlSize(.small)
                    }

                    Toggle(
                        ZtatL10n.tr("菜单栏显示", "Show in Menu Bar"),
                        isOn: Binding(
                            get: { summary.isEnabled },
                            set: { newValue in
                                self.host.setModuleEnabled(summary.id, enabled: newValue)
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!summary.isAvailable)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            StatsEmbeddedNSViewHost(target: self.target, host: self.host)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            self.isPreviewActive = false
            self.host.refreshSummaries()
            self.host.setModulePreview(self.target, visible: false)
            self.host.setEmbeddedSettingsTarget(self.target)
        }
        .onChange(of: self.target) { _, newTarget in
            self.isPreviewActive = false
            self.host.setModulePreview(newTarget, visible: false)
            self.host.setEmbeddedSettingsTarget(newTarget)
        }
        .onDisappear {
            self.host.setEmbeddedSettingsTarget(nil)
        }
    }
}

private final class StatsEmbeddedHostContainerView: NSView {
    private var currentTarget: String?
    private weak var hostedView: NSView?

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        NotificationCenter.default.post(name: .clickInSettings, object: nil, userInfo: nil)
    }

    @MainActor
    func display(target: String, host: ZtatStatsHost) {
        guard self.currentTarget != target || self.hostedView?.superview !== self else { return }
        self.currentTarget = target

        self.hostedView?.removeFromSuperview()
        self.subviews.forEach { $0.removeFromSuperview() }

        let child = host.embeddedSettingsView(for: target)
        child.removeFromSuperview()
        child.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            child.topAnchor.constraint(equalTo: self.topAnchor),
            child.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])
        self.hostedView = child
    }
}

@MainActor
private struct StatsEmbeddedNSViewHost: NSViewRepresentable {
    let target: String
    let host: ZtatStatsHost

    func makeNSView(context: Context) -> StatsEmbeddedHostContainerView {
        let container = StatsEmbeddedHostContainerView(frame: .zero)
        container.display(target: self.target, host: self.host)
        return container
    }

    func updateNSView(_ nsView: StatsEmbeddedHostContainerView, context: Context) {
        nsView.display(target: self.target, host: self.host)
    }
}
