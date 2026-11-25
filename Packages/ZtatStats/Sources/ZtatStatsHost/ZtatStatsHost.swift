// SPDX-License-Identifier: GPL-3.0-or-later
//
//  ZtatStatsHost.swift
//  ZtatStatsHost
//
//  ZTAT-PATCH: Unified pure-SwiftPM host facade for all 9 Stats hardware modules.
//  Enforces strict zero-idle startup (0 modules enabled by default, 0 fallback AppIcon,
//  0 auto-opened SettingsWindow) and exposes the ZtatStatsHost public API contract.
//

import AppKit
import Combine
import Foundation
import StatsBattery
import StatsBluetooth
import StatsCPU
import StatsClock
import StatsDisk
import StatsGPU
import StatsKit
import StatsNet
import StatsRAM
import StatsSensors
import ZtatCore

public struct StatsModuleSummary: Identifiable, Equatable, Sendable {
    public let id: String           // module config name e.g. "CPU"
    public let displayName: String  // localized label
    public let symbolName: String   // SF Symbol
    public let isEnabled: Bool
    public let isAvailable: Bool
    public let liveBadge: String    // concise live reading or "未启用"

    public init(
        id: String,
        displayName: String,
        symbolName: String,
        isEnabled: Bool,
        isAvailable: Bool,
        liveBadge: String
    ) {
        self.id = id
        self.displayName = displayName
        self.symbolName = symbolName
        self.isEnabled = isEnabled
        self.isAvailable = isAvailable
        self.liveBadge = liveBadge
    }
}

@MainActor
public final class ZtatStatsHost: ObservableObject {
    public static let shared = ZtatStatsHost()

    @Published public private(set) var enabledModuleCount: Int = 0
    @Published public private(set) var moduleSummaries: [StatsModuleSummary] = []
    @Published public private(set) var isCombinedModulesEnabled: Bool = false

    private var isStarted: Bool = false
    private var combinedView: CombinedView?
    private var settingsWindow: SettingsWindow?
    private var observers: [NSObjectProtocol] = []
    private var liveBadges: [String: String] = [:]

    private init() {
        self.isCombinedModulesEnabled = Store.shared.bool(key: "CombinedModules", defaultValue: false)
    }

    public func start() {
        guard !self.isStarted else { return }
        self.isStarted = true

        ZtatStatsStatusBarWorkaround.suppressStatusBarTilingConstraintUpdates()
        _ = SystemKit.shared

        let createdModules: [Module] = [
            CPU(),
            GPU(),
            RAM(),
            Disk(),
            Sensors(),
            Network(),
            Battery(),
            Bluetooth(),
            Clock()
        ]
        modules = createdModules

        for module in createdModules {
            module.liveBadgeCallback = { [weak self] moduleName, badge in
                Task { @MainActor [weak self] in
                    self?.handleLiveBadgeUpdate(moduleName: moduleName, badge: badge)
                }
            }
        }

        let combined = CombinedView()
        self.combinedView = combined

        // STRICT ZERO-IDLE RULE:
        // Only mount modules that the user has explicitly enabled in Store.
        // When 0 modules are enabled: 0 NSStatusItems are created, 0 readers start,
        // NO fallback AppIcon is shown, and SettingsWindow is NEVER auto-opened.
        let activeList = createdModules.filter { $0.enabled && $0.available }
        if !activeList.isEmpty {
            createdModules.reversed().forEach { module in
                if module.enabled && module.available {
                    module.mount()
                }
            }
        }
        combined.syncVisibility()

        self.installObservers()
        self.refreshSummaries()
    }

    public func terminate() {
        guard self.isStarted else { return }

        for token in self.observers {
            NotificationCenter.default.removeObserver(token)
        }
        self.observers.removeAll()

        modules.forEach { $0.terminate() }
        self.combinedView?.disable()
        self.combinedView = nil
        self.settingsWindow?.close()
        self.settingsWindow = nil

        DB.shared.terminate()
        self.isStarted = false
    }

    public func setModuleEnabled(_ name: String, enabled: Bool) {
        if !self.isStarted {
            self.start()
        }
        guard let module = self.findModule(named: name) else { return }
        guard module.available else { return }

        if enabled {
            // Ensure at least the module's default widget is active so enabling always mounts a visible widget
            if !module.menuBar.widgets.contains(where: { $0.isActive }) {
                if let defaultWidget = module.menuBar.widgets.first(where: { $0.type == module.config.defaultWidget }) ?? module.menuBar.widgets.first {
                    defaultWidget.toggle(true)
                }
            }
            if !module.enabled {
                module.enable()
            }
        } else {
            if module.enabled {
                module.disable()
            }
            self.liveBadges.removeValue(forKey: module.config.name)
        }

        self.combinedView?.syncVisibility()
        self.refreshSummaries()
        NotificationCenter.default.post(name: .ztatStatsDidChange, object: nil)
    }

    public func isModuleEnabled(_ name: String) -> Bool {
        if let module = self.findModule(named: name) {
            return module.enabled && module.available
        }
        return Store.shared.bool(key: "\(name)_state", defaultValue: false)
    }

    public func setCombinedModulesEnabled(_ enabled: Bool) {
        if !self.isStarted {
            self.start()
        }
        Store.shared.set(key: "CombinedModules", value: enabled)
        self.isCombinedModulesEnabled = enabled
        NotificationCenter.default.post(name: .toggleOneView, object: nil, userInfo: nil)
        self.combinedView?.syncVisibility()
        self.refreshSummaries()
        NotificationCenter.default.post(name: .ztatStatsDidChange, object: nil)
    }

    public func disableAllModules() {
        if !self.isStarted {
            self.start()
        }
        for module in modules where module.enabled {
            module.disable()
            self.liveBadges.removeValue(forKey: module.config.name)
        }
        self.combinedView?.syncVisibility()
        self.refreshSummaries()
        NotificationCenter.default.post(name: .ztatStatsDidChange, object: nil)
    }

    public func openNativeStatsSettings() {
        self.openNativeStatsSettings(selecting: nil)
    }

    public func openNativeStatsSettings(selecting moduleName: String?) {
        if !self.isStarted {
            self.start()
        }
        let window = self.ensureSettingsWindow()
        window.open(module: moduleName ?? "Dashboard")
    }

    public func resetAllStatsPreferences() {
        if !self.isStarted {
            self.start()
        }

        for module in modules where module.enabled {
            module.disable()
        }
        self.liveBadges.removeAll()
        self.combinedView?.disable()
        Store.shared.reset()
        self.isCombinedModulesEnabled = false

        // Sync closed native settings window cleanly if open
        self.settingsWindow?.close()
        self.settingsWindow = nil

        self.combinedView?.syncVisibility()
        self.refreshSummaries()
        NotificationCenter.default.post(name: .ztatStatsDidChange, object: nil)
    }

    public func refreshSummaries() {
        self.isCombinedModulesEnabled = Store.shared.bool(key: "CombinedModules", defaultValue: false)

        if !self.isStarted {
            self.enabledModuleCount = 0
            self.moduleSummaries = Self.defaultModuleDescriptors.map { descriptor in
                let enabled = Store.shared.bool(key: "\(descriptor.id)_state", defaultValue: false)
                return StatsModuleSummary(
                    id: descriptor.id,
                    displayName: Self.localizedDisplayName(for: descriptor.id),
                    symbolName: descriptor.symbolName,
                    isEnabled: enabled,
                    isAvailable: true,
                    liveBadge: enabled ? ZtatL10n.tr("监控中", "Active") : ZtatL10n.tr("未启用", "Off")
                )
            }
            self.enabledModuleCount = self.moduleSummaries.filter { $0.isEnabled }.count
            return
        }

        let offLabel = ZtatL10n.tr("未启用", "Off")
        let unavailableLabel = ZtatL10n.tr("不可用", "N/A")
        let activePlaceholder = ZtatL10n.tr("监控中", "Active")

        var summaries: [StatsModuleSummary] = []
        var enabledCount = 0

        for module in modules {
            let id = module.config.name
            let enabled = module.enabled && module.available
            if enabled { enabledCount += 1 }

            let badge: String
            if !module.available {
                badge = unavailableLabel
            } else if !enabled {
                badge = offLabel
            } else if let live = self.liveBadges[id] ?? module.latestLiveBadge, !live.isEmpty {
                badge = live
            } else {
                badge = activePlaceholder
            }

            summaries.append(StatsModuleSummary(
                id: id,
                displayName: Self.localizedDisplayName(for: id),
                symbolName: Self.symbolName(for: module),
                isEnabled: enabled,
                isAvailable: module.available,
                liveBadge: badge
            ))
        }

        if self.enabledModuleCount != enabledCount {
            self.enabledModuleCount = enabledCount
        }
        if self.moduleSummaries != summaries {
            self.moduleSummaries = summaries
        }
    }

    // MARK: - Private

    private func ensureSettingsWindow() -> SettingsWindow {
        if let window = self.settingsWindow {
            return window
        }
        let window = SettingsWindow()
        window.onClose = { [weak self] in
            self?.settingsWindow = nil
        }
        self.settingsWindow = window
        return window
    }

    private func findModule(named name: String) -> Module? {
        modules.first { $0.config.name == name }
            ?? modules.first { $0.config.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func handleLiveBadgeUpdate(moduleName: String, badge: String) {
        guard self.liveBadges[moduleName] != badge else { return }
        self.liveBadges[moduleName] = badge
        self.refreshSummaries()
    }

    private func installObservers() {
        let nc = NotificationCenter.default

        self.observers.append(nc.addObserver(forName: .toggleSettings, object: nil, queue: .main) { [weak self] note in
            let moduleName = note.userInfo?["module"] as? String
            Task { @MainActor [weak self] in
                self?.openNativeStatsSettings(selecting: moduleName)
            }
        })

        self.observers.append(nc.addObserver(forName: .toggleModule, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.combinedView?.syncVisibility()
                self?.refreshSummaries()
                NotificationCenter.default.post(name: .ztatStatsDidChange, object: nil)
            }
        })

        self.observers.append(nc.addObserver(forName: .toggleOneView, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.combinedView?.syncVisibility()
                self?.refreshSummaries()
            }
        })

        self.observers.append(nc.addObserver(forName: .pause, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                let paused = Store.shared.bool(key: "pause", defaultValue: false)
                for module in modules {
                    if paused && module.enabled {
                        module.disable()
                    } else if !paused && !module.enabled && Store.shared.bool(key: "\(module.config.name)_state", defaultValue: false) {
                        module.enable()
                    }
                }
                self?.combinedView?.syncVisibility()
                self?.refreshSummaries()
                NotificationCenter.default.post(name: .ztatStatsDidChange, object: nil)
            }
        })
    }

    private static let defaultModuleDescriptors: [(id: String, symbolName: String)] = [
        ("CPU", "cpu.fill"),
        ("GPU", "display"),
        ("RAM", "memorychip"),
        ("Disk", "internaldrive.fill"),
        ("Sensors", "thermometer.medium"),
        ("Network", "network"),
        ("Battery", "battery.75percent"),
        ("Bluetooth", "dot.radiowaves.left.and.right"),
        ("Clock", "clock.fill")
    ]

    private static func symbolName(for module: Module) -> String {
        let configured = module.config.symbolName
        if !configured.isEmpty, NSImage(systemSymbolName: configured, accessibilityDescription: nil) != nil {
            return configured
        }
        return defaultModuleDescriptors.first(where: { $0.id == module.config.name })?.symbolName
            ?? "gauge.with.dots.needle.67percent"
    }

    private static func localizedDisplayName(for id: String) -> String {
        switch id {
        case "CPU": return ZtatL10n.tr("处理器 (CPU)", "CPU")
        case "GPU": return ZtatL10n.tr("图形 (GPU)", "GPU")
        case "RAM": return ZtatL10n.tr("内存 (RAM)", "Memory")
        case "Disk": return ZtatL10n.tr("磁盘", "Disk")
        case "Sensors": return ZtatL10n.tr("传感器", "Sensors")
        case "Network": return ZtatL10n.tr("网络", "Network")
        case "Battery": return ZtatL10n.tr("电池", "Battery")
        case "Bluetooth": return ZtatL10n.tr("蓝牙", "Bluetooth")
        case "Clock": return ZtatL10n.tr("时钟", "Clock")
        default: return localizedString(id)
        }
    }
}
