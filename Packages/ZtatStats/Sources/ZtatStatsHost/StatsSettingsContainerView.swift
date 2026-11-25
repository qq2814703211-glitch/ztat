// SPDX-License-Identifier: GPL-3.0-or-later
//
//  StatsSettingsContainerView.swift
//  ZtatStatsHost
//
//  Settings view hosted inside ztat's unified Settings window "性能监控" section.
//

import StatsKit
import SwiftUI
import ZtatCore

/// Settings view hosted inside ztat's unified Settings window "性能监控" section.
@MainActor
public struct StatsSettingsContainerView: View {
    @ObservedObject private var host: ZtatStatsHost
    @State private var temperatureUnit: String
    @State private var keepMenuBarPosition: Bool
    @State private var showResetConfirmation: Bool = false

    public init(host: ZtatStatsHost) {
        self.host = host
        _temperatureUnit = State(initialValue: Store.shared.string(key: "temperature_units", defaultValue: "system"))
        _keepMenuBarPosition = State(initialValue: Store.shared.bool(key: "keep_menubar_positions", defaultValue: false))
    }

    public init() {
        self.init(host: .shared)
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

                    Button(ZtatL10n.tr("高级组件设置…", "Advanced Widget Settings…")) {
                        self.host.openNativeStatsSettings()
                    }
                    .controlSize(.regular)
                }
            }

            Section(ZtatL10n.tr("菜单栏模块", "Menu Bar Modules")) {
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

                        Button(ZtatL10n.tr("自定义", "Customize")) {
                            self.host.openNativeStatsSettings(selecting: item.id)
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
