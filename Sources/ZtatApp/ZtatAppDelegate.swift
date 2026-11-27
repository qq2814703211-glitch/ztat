// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Darwin
import SwiftUI
import ZtatCore
import ZtatPowerGuard
import ZtatStatsHost
import StatusTrioCore
import ZtatIsland
import ZtatCleaner
import VorssaintToolbox

@MainActor
final class ZtatAppDelegate: NSObject, NSApplicationDelegate, ZtatHubPanelContentProviding, ZtatHostActionHandling {
    private var settingsObserver: NSObjectProtocol?
    private var appUninstallerObserver: NSObjectProtocol?
    private var taskManagerToggleObserver: NSObjectProtocol?
    private var taskManagerOpenObserver: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []
    private var instanceLockFD: Int32 = -1

    private func acquireSingleInstanceLock() -> Bool {
        let fm = FileManager.default
        let cachesDir = (fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? ZtatBrand.activeBundleIdentifier, isDirectory: true)
        try? fm.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        let lockPath = cachesDir.appendingPathComponent("instance.lock").path

        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }

        // Retry briefly (~1.5s) so an intentional relaunch smoothly inherits the lock
        // while the outgoing process is finishing applicationWillTerminate.
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0

        for attempt in 0..<30 {
            if Darwin.fcntl(fd, F_SETLK, &lock) == 0 {
                instanceLockFD = fd
                return true
            }
            if attempt < 29 {
                usleep(50_000)
            }
        }
        Darwin.close(fd)
        return false
    }

    private func releaseSingleInstanceLock() {
        if instanceLockFD >= 0 {
            var unlock = Darwin.flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            unlock.l_start = 0
            unlock.l_len = 0
            _ = Darwin.fcntl(instanceLockFD, F_SETLK, &unlock)
            Darwin.close(instanceLockFD)
            instanceLockFD = -1
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard using an exclusive flock + live peer check so relaunch never races into mutual termination.
        if !acquireSingleInstanceLock() {
            if let bundleID = Bundle.main.bundleIdentifier {
                let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
                if let existing = others.first {
                    existing.activate()
                }
            }
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        installTerminationSignalHandlers()
        installStandardMainMenu()
        ZtatHostBridge.shared.register(self)
        ZtatAppearanceStore.shared.apply()

        // 1. PowerGuard first: immediate crash recovery (restores orphaned brightness or disablesleep)
        //    and registers unified pmset power control into ZtatPowerGuardRegistry.
        PowerGuardCoordinator.shared.start()

        // 2. Status host: sole primary NSStatusItem + Liquid Glass AnchoredStatusPanel hosting ZtatHubRootView.
        ZtatStatusTrioHost.shared.start(hubContentProvider: self)

        // 3. Hardware Monitor engine: mounts ONLY user-enabled hardware metrics (zero idle AppIcon, zero auto SettingsWindow).
        ZtatStatsHost.shared.start()

        // 4. Toolbox host: lazily starts only user-enabled non-overlapping utilities
        //    (NO standalone extra menu bar icon, NO duplicate monitors/keepAwake/notch).
        ZtatVorssaintHost.shared.start()

        // 5. Native Dynamic Island (Atoll engine): migrates local Atoll prefs once and starts notch & lock-screen host.
        ZtatIslandHost.migratePreferencesFromAtollIfNeeded()
        ZtatIslandHost.shared.start()

        // 6. Native App Cleaner & Uninstaller (Pearcleaner-inspired clean-room engine): zero-idle unless Trash Sentinel is enabled.
        ZtatCleanerHost.shared.start()
        NSApp.servicesProvider = self

        // 7. Install global shortcut for Standalone Task Manager (default ⌃⇧⎋, customizable)
        ZtatTaskManagerWindowController.shared.installGlobalShortcutIfNeeded()

        appUninstallerObserver = NotificationCenter.default.addObserver(
            forName: .ztatOpenAppUninstaller,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let url = note.object as? URL else { return }
            Task { @MainActor [weak self] in
                self?.dismissHubPanel()
                ZtatCleanerHost.shared.openUninstaller(for: url)
            }
        }

        taskManagerToggleObserver = NotificationCenter.default.addObserver(
            forName: .ztatToggleTaskManager,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                ZtatTaskManagerWindowController.shared.toggle()
            }
        }

        taskManagerOpenObserver = NotificationCenter.default.addObserver(
            forName: .ztatOpenTaskManager,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissHubPanel()
                ZtatTaskManagerWindowController.shared.show()
            }
        }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .ztatOpenSettings,
            object: nil,
            queue: .main
        ) { note in
            let route: ZtatSettingsRoute
            if let r = note.object as? ZtatSettingsRoute {
                route = r
            } else if let s = note.object as? ZtatSettingsSection {
                route = ZtatSettingsRoute(section: s)
            } else if let raw = note.object as? String, let s = ZtatSettingsSection(rawValue: raw) {
                route = ZtatSettingsRoute(section: s)
            } else {
                route = .general
            }
            Task { @MainActor in
                self.openSettings(route: route)
            }
        }

        ZtatLog.app.info("ztat \(ZtatBrand.version, privacy: .public) launched successfully.")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            ZtatStatusTrioHost.shared.showHubPanel()
        }
        ZtatVorssaintHost.shared.handleReopen()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == "ztat" {
                _ = ZtatCleanerHost.shared.handleIncomingURL(url)
            } else if url.isFileURL && url.pathExtension.lowercased() == "app" {
                ZtatCleanerHost.shared.openUninstaller(for: url)
            }
        }
    }

    /// macOS Finder Services handler (`Uninstall with ztat`).
    @objc func handleUninstallServiceRequest(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let apps = urls.filter { $0.pathExtension.lowercased() == "app" }
        guard let first = apps.first else { return }
        if apps.count > 1 {
            ZtatCleanerHost.shared.externalQueue.append(contentsOf: apps.dropFirst())
        }
        ZtatCleanerHost.shared.openUninstaller(for: first)
    }

    func applicationWillTerminate(_ notification: Notification) {
        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()

        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        if let appUninstallerObserver {
            NotificationCenter.default.removeObserver(appUninstallerObserver)
            self.appUninstallerObserver = nil
        }
        if let taskManagerToggleObserver {
            NotificationCenter.default.removeObserver(taskManagerToggleObserver)
            self.taskManagerToggleObserver = nil
        }
        if let taskManagerOpenObserver {
            NotificationCenter.default.removeObserver(taskManagerOpenObserver)
            self.taskManagerOpenObserver = nil
        }

        // Clean ordered teardown:
        ZtatTaskManagerWindowController.shared.uninstallGlobalShortcut()
        ZtatCleanerHost.shared.stop()
        ZtatIslandHost.shared.stop()
        ZtatVorssaintHost.shared.stop()
        ZtatStatsHost.shared.terminate()
        ZtatStatusTrioHost.shared.stop()
        PowerGuardCoordinator.shared.stopForTermination()
        releaseSingleInstanceLock()
    }

    private func installTerminationSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Standard Main Menu (enables Cmd+C/V/X/A/Z/W/M/H/, inside Settings text fields)

    private func installStandardMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: ZtatBrand.appName)
        let settingsItem = NSMenuItem(
            title: ZtatL10n.tr("设置…", "Settings…"),
            action: #selector(openGeneralSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: ZtatL10n.tr("隐藏 \(ZtatBrand.appName)", "Hide \(ZtatBrand.appName)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: ZtatL10n.tr("隐藏其他", "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: ZtatL10n.tr("显示全部", "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: ZtatL10n.tr("退出 \(ZtatBrand.appName)", "Quit \(ZtatBrand.appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: ZtatL10n.tr("编辑", "Edit"))
        editMenu.addItem(withTitle: ZtatL10n.tr("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: ZtatL10n.tr("重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: ZtatL10n.tr("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: ZtatL10n.tr("拷贝", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: ZtatL10n.tr("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: ZtatL10n.tr("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: ZtatL10n.tr("窗口", "Window"))
        let taskMgrItem = NSMenuItem(
            title: ZtatL10n.tr("任务管理器", "Task Manager"),
            action: #selector(openTaskManagerFromMenu),
            keyEquivalent: ""
        )
        taskMgrItem.target = self
        windowMenu.addItem(taskMgrItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: ZtatL10n.tr("关闭窗口", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: ZtatL10n.tr("最小化", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - ZtatHostActionHandling

    var keepsPanelOpenWhenOpeningSettings: Bool {
        ZtatStatusTrioHost.shared.keepsPanelOpenWhenOpeningSettings
    }

    func dismissHubPanel() {
        ZtatStatusTrioHost.shared.dismissHubPanel()
    }

    func showHubPanel(tab: ZtatHubTab?) {
        ZtatStatusTrioHost.shared.showHubPanel()
        if let tab {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .ztatOpenHubTab, object: tab)
            }
        }
    }

    func openSettings(route: ZtatSettingsRoute) {
        if !keepsPanelOpenWhenOpeningSettings {
            ZtatStatusTrioHost.shared.dismissHubPanel()
        }
        ZtatSettingsWindowController.shared.show(route: route)
    }

    func primaryStatusItemFrame() -> NSRect? {
        ZtatStatusTrioHost.shared.primaryStatusItemFrame()
    }

    func relaunchApp() {
        ZtatHostBridge.performDefaultRelaunch()
    }

    // MARK: - ZtatHubPanelContentProviding

    func makeHubRootView(statusTrioBody: AnyView) -> AnyView {
        AnyView(
            ZtatHubRootView(
                statusTrioBody: statusTrioBody,
                onOpenSettings: { [weak self] route in
                    self?.openSettings(route: route)
                }
            )
        )
    }

    func makeExtraContextMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let shortcutHint = ZtatTaskManagerShortcutStore.shared.displayString
        let taskMgrItem = NSMenuItem(
            title: ZtatL10n.tr("打开任务管理器 (\(shortcutHint))", "Open Task Manager (\(shortcutHint))"),
            action: #selector(openTaskManagerFromMenu),
            keyEquivalent: ""
        )
        taskMgrItem.target = self
        items.append(taskMgrItem)

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

        let islandItem = NSMenuItem(
            title: ZtatIslandHost.shared.isEnabled
                ? ZtatL10n.tr("展开/收起灵动岛", "Toggle Dynamic Island")
                : ZtatL10n.tr("启用灵动岛", "Enable Dynamic Island"),
            action: #selector(toggleIslandFromMenu),
            keyEquivalent: ""
        )
        islandItem.target = self
        islandItem.state = ZtatIslandHost.shared.isEnabled ? .on : .off
        items.append(islandItem)

        let cleanerItem = NSMenuItem(
            title: ZtatL10n.tr("应用卸载与深度清理…", "App Uninstaller & Cleaner…"),
            action: #selector(openCleanerFromMenu),
            keyEquivalent: ""
        )
        cleanerItem.target = self
        items.append(cleanerItem)

        let statsItem = NSMenuItem(
            title: ZtatL10n.tr("性能监控指标配置…", "Hardware Monitor Metrics…"),
            action: #selector(openStatsSettingsFromMenu),
            keyEquivalent: ""
        )
        statsItem.target = self
        items.append(statsItem)

        let toolsItem = NSMenuItem(
            title: ZtatL10n.tr("系统工具箱管理…", "Utility Toolbox Settings…"),
            action: #selector(openToolboxSettingsFromMenu),
            keyEquivalent: ""
        )
        toolsItem.target = self
        items.append(toolsItem)

        return items
    }

    func openUnifiedSettings() {
        openSettings(route: .general)
    }

    func hubPanelVisibilityDidChange(isVisible: Bool) {
        NotificationCenter.default.post(
            name: .ztatHubPanelVisibilityDidChange,
            object: isVisible,
            userInfo: ["visible": isVisible]
        )
    }

    // MARK: - Context & Main Menu Actions

    @objc private func openTaskManagerFromMenu() {
        ZtatTaskManagerWindowController.shared.show()
    }

    @objc private func openGeneralSettingsFromMenu() {
        openSettings(route: .general)
    }

    @objc private func togglePowerGuardFromMenu() {
        PowerGuardCoordinator.shared.toggleRemoteReadyMode()
    }

    @objc private func toggleBlackoutFromMenu() {
        PowerGuardCoordinator.shared.toggleBlackoutMode()
    }

    @objc private func toggleIslandFromMenu() {
        if ZtatIslandHost.shared.isEnabled {
            ZtatIslandHost.shared.toggleNotchOpen()
        } else {
            ZtatIslandHost.shared.setEnabled(true)
        }
    }

    @objc private func openCleanerFromMenu() {
        openSettings(route: .cleaner(sectionID: "apps"))
    }

    @objc private func openStatsSettingsFromMenu() {
        openSettings(route: .stats(target: "overview"))
    }

    @objc private func openToolboxSettingsFromMenu() {
        openSettings(route: .toolbox(itemID: nil))
    }
}
