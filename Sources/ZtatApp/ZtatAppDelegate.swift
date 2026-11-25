// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import ZtatCore
import ZtatPowerGuard
import ZtatStatsHost
import StatusTrioCore
import VorssaintToolbox

@MainActor
final class ZtatAppDelegate: NSObject, NSApplicationDelegate, ZtatHubPanelContentProviding {
    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: activate existing running instance and exit cleanly if duplicated
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                existing.activate()
                NSApp.terminate(nil)
                return
            }
        }

        NSApp.setActivationPolicy(.accessory)

        // 1. PowerGuard first: immediate crash recovery (restores orphaned brightness or disablesleep)
        //    and registers into ZtatCore.ZtatPowerGuardRegistry so Vorssaint Dynamic Island & Hub stay in sync.
        PowerGuardCoordinator.shared.start()

        // 2. Status Trio: sole primary NSStatusItem + Liquid Glass AnchoredStatusPanel hosting ZtatHubRootView.
        ZtatStatusTrioHost.shared.start(hubContentProvider: self)

        // 3. Stats engine: mounts ONLY user-enabled hardware metrics (zero idle AppIcon, zero auto SettingsWindow).
        ZtatStatsHost.shared.start()

        // 4. Vorssaint deduplicated toolbox: lazily starts only user-enabled non-overlapping utilities
        //    (NO standalone Vorssaint menu bar icon, NO duplicate monitors/fanControl/keepAwake).
        ZtatVorssaintHost.shared.start()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .ztatOpenSettings,
            object: nil,
            queue: .main
        ) { note in
            let section: ZtatSettingsSection
            if let s = note.object as? ZtatSettingsSection {
                section = s
            } else if let raw = note.object as? String, let s = ZtatSettingsSection(rawValue: raw) {
                section = s
            } else {
                section = .general
            }
            Task { @MainActor in
                ZtatSettingsWindowController.shared.show(section: section)
            }
        }

        ZtatLog.app.info("ztat \(ZtatBrand.version, privacy: .public) launched successfully.")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ZtatStatusTrioHost.shared.showHubPanel()
        ZtatVorssaintHost.shared.handleReopen()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }

        // Clean ordered teardown:
        // 1. Only stop actually-started Vorssaint services (zero singleton instantiation storm)
        ZtatVorssaintHost.shared.stop()
        // 2. Flush Stats debounced JSON cache & stop active readers
        ZtatStatsHost.shared.terminate()
        // 3. Stop Status Trio monitors
        ZtatStatusTrioHost.shared.stop()
        // 4. Restore display brightness & default sleep policy if configured
        PowerGuardCoordinator.shared.stopForTermination()
    }

    // MARK: - ZtatHubPanelContentProviding

    func makeHubRootView(statusTrioBody: AnyView) -> AnyView {
        AnyView(
            ZtatHubRootView(
                statusTrioBody: statusTrioBody,
                onOpenSettings: { section in
                    ZtatStatusTrioHost.shared.dismissHubPanel()
                    ZtatSettingsWindowController.shared.show(section: section)
                }
            )
        )
    }

    func makeExtraContextMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let pg = PowerGuardCoordinator.shared
        let guardTitle = pg.isAnyGuardActive
            ? ZtatL10n.tr("停止保活与合盖锁", "Disable Keep-Awake Guard")
            : ZtatL10n.tr("一键合盖+远程保活", "Enable Remote-Ready Guard")
        let guardItem = NSMenuItem(title: guardTitle, action: #selector(togglePowerGuardFromMenu), keyEquivalent: "")
        guardItem.target = self
        guardItem.state = pg.isAnyGuardActive ? .on : .off
        items.append(guardItem)

        let blackoutTitle = pg.isBlackoutActive
            ? ZtatL10n.tr("退出物理熄屏 (恢复亮度)", "Exit Physical Blackout")
            : ZtatL10n.tr("开启物理熄屏 0% (⌘⌥B 恢复)", "Enable 0% Physical Blackout")
        let blackoutItem = NSMenuItem(title: blackoutTitle, action: #selector(toggleBlackoutFromMenu), keyEquivalent: "")
        blackoutItem.target = self
        blackoutItem.state = pg.isBlackoutActive ? .on : .off
        items.append(blackoutItem)

        let statsItem = NSMenuItem(
            title: ZtatL10n.tr("性能监控指标配置...", "Hardware Stats Metrics..."),
            action: #selector(openStatsSettingsFromMenu),
            keyEquivalent: ""
        )
        statsItem.target = self
        items.append(statsItem)

        let toolsItem = NSMenuItem(
            title: ZtatL10n.tr("系统工具箱管理...", "Utility Toolbox Settings..."),
            action: #selector(openToolboxSettingsFromMenu),
            keyEquivalent: ""
        )
        toolsItem.target = self
        items.append(toolsItem)

        return items
    }

    func openUnifiedSettings() {
        ZtatStatusTrioHost.shared.dismissHubPanel()
        ZtatSettingsWindowController.shared.show(section: .general)
    }

    func hubPanelVisibilityDidChange(isVisible: Bool) {
        NotificationCenter.default.post(name: .ztatHubPanelVisibilityDidChange, object: isVisible)
        if !isVisible {
            PowerGuardCoordinator.shared.setPanelVisible(false)
        }
    }

    // MARK: - Context Menu Actions

    @objc private func togglePowerGuardFromMenu() {
        PowerGuardCoordinator.shared.toggleRemoteReadyMode()
    }

    @objc private func toggleBlackoutFromMenu() {
        PowerGuardCoordinator.shared.toggleBlackoutMode()
    }

    @objc private func openStatsSettingsFromMenu() {
        ZtatSettingsWindowController.shared.show(section: .stats)
    }

    @objc private func openToolboxSettingsFromMenu() {
        ZtatSettingsWindowController.shared.show(section: .toolbox)
    }
}
