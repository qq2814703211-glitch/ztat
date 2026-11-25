// SPDX-License-Identifier: GPL-3.0-or-later
//
//  StatsHubControlView.swift
//  ZtatStatsHost
//
//  Compact 356pt SwiftUI view hosted inside ztat's unified Liquid Glass Hub "监控" tab.
//

import StatsKit
import SwiftUI
import ZtatCore

/// Compact 356pt SwiftUI view hosted inside ztat's unified Liquid Glass Hub "监控" tab.
/// Lets the user toggle each of the 9 Stats menu bar metrics on/off immediately,
/// toggle "Combine modules" mode, and open full Stats widget/popup settings.
@MainActor
public struct StatsHubControlView: View {
    @ObservedObject private var host: ZtatStatsHost
    private let onOpenSettings: (() -> Void)?

    public init(host: ZtatStatsHost, onOpenSettings: (() -> Void)? = nil) {
        self.host = host
        self.onOpenSettings = onOpenSettings
    }

    public init(onOpenSettings: (() -> Void)? = nil) {
        self.host = .shared
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.headerBar

            VStack(spacing: 4) {
                ForEach(self.host.moduleSummaries) { item in
                    self.moduleRow(item)
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
            )

            self.footerControls
        }
        .frame(width: ZtatBrand.hubPanelWidth - 24, alignment: .leading)
        .onAppear {
            self.host.refreshSummaries()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Label {
                Text(ZtatL10n.tr("菜单栏性能监控", "Menu Bar Monitors"))
                    .font(.system(size: 13, weight: .semibold))
            } icon: {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
            }

            Spacer(minLength: 4)

            Text(
                self.host.enabledModuleCount == 0
                    ? ZtatL10n.tr("全部待机", "All Idle")
                    : ZtatL10n.tr("已启用 \(self.host.enabledModuleCount) 项", "\(self.host.enabledModuleCount) Active")
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(self.host.enabledModuleCount > 0 ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (self.host.enabledModuleCount > 0 ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12)),
                in: Capsule()
            )

            if self.host.enabledModuleCount > 0 {
                Button {
                    self.host.disableAllModules()
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(ZtatL10n.tr("关闭全部监控项", "Disable all monitors"))
            }
        }
    }

    private func moduleRow(_ item: StatsModuleSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbolName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20, height: 20)
                .foregroundStyle(item.isEnabled ? Color.accentColor : Color.secondary)

            Text(item.displayName)
                .font(.system(size: 12.5, weight: item.isEnabled ? .medium : .regular))
                .foregroundStyle(item.isAvailable ? .primary : .tertiary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(item.liveBadge)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(item.isEnabled ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    (item.isEnabled ? Color.primary.opacity(0.08) : Color.clear),
                    in: Capsule()
                )

            Button {
                self.host.openNativeStatsSettings(selecting: item.id)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!item.isAvailable)
            .help(ZtatL10n.tr("自定义 \(item.displayName) 组件样式与弹窗", "Customize \(item.displayName) widget & popup"))

            Toggle("", isOn: Binding(
                get: { item.isEnabled },
                set: { newValue in
                    self.host.setModuleEnabled(item.id, enabled: newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!item.isAvailable)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            item.isEnabled ? Color.accentColor.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var footerControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(ZtatL10n.tr("合并为单个菜单栏项", "Combine modules"))
                    .font(.system(size: 12))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { self.host.isCombinedModulesEnabled },
                    set: { newValue in
                        self.host.setCombinedModulesEnabled(newValue)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                if let onOpenSettings = self.onOpenSettings {
                    onOpenSettings()
                } else {
                    self.host.openNativeStatsSettings()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.below.rectangle")
                        .font(.system(size: 12, weight: .medium))
                    Text(ZtatL10n.tr("打开完整组件与弹窗设置…", "Open Full Widget & Popup Settings…"))
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
