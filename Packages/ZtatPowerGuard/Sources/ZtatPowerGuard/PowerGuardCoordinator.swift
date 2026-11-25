// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon
import Combine
import Foundation
import IOKit.pwr_mgt
import ZtatCore

/// Authoritative @MainActor coordinator for ztat's unified Keep-Awake, Clamshell Lock,
/// Physical 0% Blackout, Framebuffer Wake Guard, Low-Battery Protection, and Diagnostics.
@MainActor
public final class PowerGuardCoordinator: ObservableObject, ZtatPowerGuardControlling {
    public static let shared = PowerGuardCoordinator()

    // MARK: - Published State
    @Published public private(set) var isIdleKeepAwakeActive: Bool = false
    @Published public private(set) var isClamshellLocked: Bool = false
    @Published public private(set) var isBlackoutActive: Bool = false
    @Published public private(set) var isBusy: Bool = false
    @Published public private(set) var expirationDate: Date? = nil
    @Published public private(set) var telemetry = PowerGuardTelemetry()
    @Published public private(set) var logs: [PowerGuardLogEntry] = []
    @Published public private(set) var toastMessage: String? = nil

    // MARK: - Persisted Preferences
    @Published public var selectedDuration: PowerGuardDuration {
        didSet { UserDefaults.standard.set(selectedDuration.rawValue, forKey: PowerGuardDefaultsKey.selectedDuration) }
    }
    @Published public var keepFramebufferAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepFramebufferAwake, forKey: PowerGuardDefaultsKey.keepFramebufferAwake)
            reconcileFramebufferTimer()
        }
    }
    @Published public var allowDisplaySleep: Bool {
        didSet {
            UserDefaults.standard.set(allowDisplaySleep, forKey: PowerGuardDefaultsKey.allowDisplaySleep)
            if isIdleKeepAwakeActive {
                refreshIdleAssertions()
            }
        }
    }
    @Published public var autoDimOnLidClose: Bool {
        didSet { UserDefaults.standard.set(autoDimOnLidClose, forKey: PowerGuardDefaultsKey.autoDimOnLidClose) }
    }
    @Published public var lowBatteryAutoRestore: Bool {
        didSet { UserDefaults.standard.set(lowBatteryAutoRestore, forKey: PowerGuardDefaultsKey.lowBatteryAutoRestore) }
    }
    @Published public var lowBatteryThreshold: Int {
        didSet { UserDefaults.standard.set(lowBatteryThreshold, forKey: PowerGuardDefaultsKey.lowBatteryThreshold) }
    }
    @Published public var restoreSleepOnQuit: Bool {
        didSet { UserDefaults.standard.set(restoreSleepOnQuit, forKey: PowerGuardDefaultsKey.restoreSleepOnQuit) }
    }

    public var isAnyGuardActive: Bool {
        isIdleKeepAwakeActive || isClamshellLocked || isBlackoutActive
    }

    // MARK: - Private Engine State
    private var systemSleepAssertionID: IOPMAssertionID = 0
    private var displaySleepAssertionID: IOPMAssertionID = 0
    private var expirationTimer: Timer?
    private var framebufferGuardTimer: Timer?
    private var visibleTelemetryTimer: Timer?
    private var toastDismissTask: Task<Void, Never>?
    private var localKeyMonitor: Any?
    private var blackoutHotKeyRef: EventHotKeyRef?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isPanelVisible = false
    private var started = false
    private var didAutoDimForLid = false

    private static var hotKeyHandlerInstalled = false

    private init() {
        let d = UserDefaults.standard
        let savedDur = d.object(forKey: PowerGuardDefaultsKey.selectedDuration) as? TimeInterval ?? PowerGuardDuration.infinite.rawValue
        self.selectedDuration = PowerGuardDuration(rawValue: savedDur) ?? .infinite
        self.keepFramebufferAwake = d.object(forKey: PowerGuardDefaultsKey.keepFramebufferAwake) as? Bool ?? true
        self.allowDisplaySleep = d.object(forKey: PowerGuardDefaultsKey.allowDisplaySleep) as? Bool ?? false
        self.autoDimOnLidClose = d.object(forKey: PowerGuardDefaultsKey.autoDimOnLidClose) as? Bool ?? true
        self.lowBatteryAutoRestore = d.object(forKey: PowerGuardDefaultsKey.lowBatteryAutoRestore) as? Bool ?? true
        self.lowBatteryThreshold = d.object(forKey: PowerGuardDefaultsKey.lowBatteryThreshold) as? Int ?? 20
        self.restoreSleepOnQuit = d.object(forKey: PowerGuardDefaultsKey.restoreSleepOnQuit) as? Bool ?? true
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        ZtatPowerGuardRegistry.shared.register(self)

        recoverFromUncleanExitIfNeeded()

        HardwarePowerProbe.shared.startObserving { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleHardwareEvent()
            }
        }

        installWorkspaceObservers()
        refreshTelemetry()

        Task { [weak self] in
            let ready = await ClamshellSudoEngine.shared.refreshPasswordlessSudoStatus()
            await MainActor.run { [weak self] in
                self?.telemetry.isPasswordlessSudoReady = ready
            }
        }
        appendLog(ZtatL10n.tr("ZtatPowerGuard 引擎已启动（事件驱动零轮询）", "ZtatPowerGuard engine started (event-driven)"))
    }

    public func stopForTermination() {
        HardwarePowerProbe.shared.stopObserving()
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        expirationTimer?.invalidate()
        framebufferGuardTimer?.invalidate()
        visibleTelemetryTimer?.invalidate()
        removeBlackoutRecoveryHooks()

        if isBlackoutActive {
            DisplayBlackoutEngine.shared.disableBlackout(retryOnFailure: false)
            isBlackoutActive = false
        }
        releaseIdleAssertions()
        DisplayBlackoutEngine.shared.releaseFramebufferWakeAssertion()

        if restoreSleepOnQuit && (isClamshellLocked || UserDefaults.standard.bool(forKey: PowerGuardDefaultsKey.sleepDisabledOwned)) {
            if ClamshellSudoEngine.shared.probePasswordlessSudoSync() {
                _ = ClamshellSudoEngine.shared.setSleepDisabledSync(false)
            }
        }
    }

    public func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        visibleTelemetryTimer?.invalidate()
        visibleTelemetryTimer = nil

        if visible {
            refreshTelemetry()
            Task { [weak self] in
                let ready = await ClamshellSudoEngine.shared.refreshPasswordlessSudoStatus()
                await MainActor.run { [weak self] in
                    self?.telemetry.isPasswordlessSudoReady = ready
                }
            }
            let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshTelemetry()
                }
            }
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            visibleTelemetryTimer = t
        }
    }

    // MARK: - ZtatPowerGuardControlling

    public var currentSnapshot: ZtatPowerGuardSnapshot {
        let remaining: TimeInterval? = expirationDate.map { max(0, $0.timeIntervalSinceNow) }
        let label: String
        if isBlackoutActive {
            label = ZtatL10n.tr("熄屏挂机 0%", "Blackout 0%")
        } else if isClamshellLocked && isIdleKeepAwakeActive {
            label = ZtatL10n.tr("合盖+关屏不休眠", "Remote-Ready")
        } else if isClamshellLocked {
            label = ZtatL10n.tr("合盖不休眠", "Clamshell Lock")
        } else if isIdleKeepAwakeActive {
            label = ZtatL10n.tr("防休眠保活中", "Keep Awake")
        } else {
            label = ZtatL10n.tr("系统默认休眠", "Default Sleep")
        }
        return ZtatPowerGuardSnapshot(
            isActive: isAnyGuardActive,
            isIdleKeepAwakeActive: isIdleKeepAwakeActive,
            isClamshellLocked: isClamshellLocked,
            isBlackoutActive: isBlackoutActive,
            isLidClosed: telemetry.lidClosed,
            isDisplayAsleep: telemetry.displayAsleep,
            isOnACPower: telemetry.isOnACPower,
            batteryPercentage: telemetry.batteryPercentage,
            remainingSeconds: remaining,
            expirationDate: expirationDate,
            summaryLabel: label
        )
    }

    public func toggleRemoteReadyMode() {
        if isAnyGuardActive {
            disableAll()
        } else {
            enableRemoteReadyMode(duration: selectedDuration)
        }
    }

    public func activateForDuration(seconds: TimeInterval?) {
        if let seconds, seconds > 0 {
            enableIdleKeepAwake(expiration: Date().addingTimeInterval(seconds))
        } else {
            enableIdleKeepAwake(expiration: nil)
        }
    }

    public func extendSession(by seconds: TimeInterval) {
        let base = expirationDate ?? Date()
        let next = base.addingTimeInterval(seconds)
        scheduleExpiration(next)
        appendLog(ZtatL10n.tr("已延长保活时长", "Extended keep-awake session"))
        publishSnapshot()
    }

    // MARK: - Primary User Actions

    public func enableRemoteReadyMode(duration: PowerGuardDuration? = nil) {
        let chosen = duration ?? selectedDuration
        selectedDuration = chosen
        let exp: Date? = chosen == .infinite ? nil : Date().addingTimeInterval(chosen.rawValue)
        enableIdleKeepAwake(expiration: exp)
        if keepFramebufferAwake {
            DisplayBlackoutEngine.shared.renewFramebufferWakeAssertion()
        }
        setClamshellLock(true)
    }

    public func disableAll() {
        expirationTimer?.invalidate()
        expirationTimer = nil
        expirationDate = nil

        if isBlackoutActive {
            _ = DisplayBlackoutEngine.shared.disableBlackout(retryOnFailure: true)
            isBlackoutActive = false
            removeBlackoutRecoveryHooks()
        }
        releaseIdleAssertions()
        DisplayBlackoutEngine.shared.releaseFramebufferWakeAssertion()
        reconcileFramebufferTimer()

        if isClamshellLocked || telemetry.sleepDisabledKernel {
            setClamshellLock(false, enforceLidSleepAfter: true)
        } else {
            refreshTelemetry()
            publishSnapshot()
            showToast(ZtatL10n.tr("已恢复系统默认休眠策略", "Restored default macOS sleep policy"))
        }
    }

    public func toggleIdleKeepAwake() {
        if isIdleKeepAwakeActive {
            releaseIdleAssertions()
            expirationTimer?.invalidate()
            expirationTimer = nil
            expirationDate = nil
            reconcileFramebufferTimer()
            appendLog(ZtatL10n.tr("已关闭空闲防休眠断言", "Disabled idle sleep assertions"))
            publishSnapshot()
        } else {
            let exp: Date? = selectedDuration == .infinite ? nil : Date().addingTimeInterval(selectedDuration.rawValue)
            enableIdleKeepAwake(expiration: exp)
        }
    }

    public func toggleClamshellLock() {
        setClamshellLock(!isClamshellLocked)
    }

    public func setClamshellLock(_ enabled: Bool, enforceLidSleepAfter: Bool = false) {
        guard !isBusy else { return }
        isBusy = true
        Task { [weak self] in
            let res = await ClamshellSudoEngine.shared.setSleepDisabled(enabled)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                if res.success {
                    self.isClamshellLocked = enabled
                    self.appendLog(
                        enabled
                            ? ZtatL10n.tr("已锁定合盖不休眠 (pmset disablesleep 1)", "Clamshell lock enabled (pmset disablesleep 1)")
                            : ZtatL10n.tr("已解除合盖不休眠 (pmset disablesleep 0)", "Clamshell lock disabled (pmset disablesleep 0)")
                    )
                    self.showToast(
                        enabled
                            ? ZtatL10n.tr("合盖+关屏不休眠已开启", "Clamshell Keep-Awake enabled")
                            : ZtatL10n.tr("已解除合盖不休眠锁", "Clamshell lock disabled")
                    )
                    if !enabled && enforceLidSleepAfter {
                        HardwarePowerProbe.shared.enforceLidSleepIfClosed()
                    }
                } else {
                    let msg = res.error ?? "unknown error"
                    self.appendLog(ZtatL10n.tr("切换合盖不休眠失败：\(msg)", "Failed to switch clamshell lock: \(msg)"), isWarning: true)
                    self.showToast(ZtatL10n.tr("操作取消或权限不足", "Cancelled or insufficient privileges"))
                }
                self.refreshTelemetry()
                self.publishSnapshot()
            }
        }
    }

    public func toggleBlackoutMode() {
        if isBlackoutActive {
            _ = DisplayBlackoutEngine.shared.disableBlackout(retryOnFailure: true)
            isBlackoutActive = false
            removeBlackoutRecoveryHooks()
            appendLog(ZtatL10n.tr("已退出物理熄屏并恢复屏幕亮度", "Exited physical blackout and restored brightness"))
            showToast(ZtatL10n.tr("已恢复屏幕亮度", "Display brightness restored"))
            refreshTelemetry()
            publishSnapshot()
            return
        }

        if !UserDefaults.standard.bool(forKey: PowerGuardDefaultsKey.hasShownBlackoutGuide) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = ZtatL10n.tr("即将开启物理熄屏挂机 (背光 0%)", "Enable Physical Blackout (0% Backlight)?")
            alert.informativeText = ZtatL10n.tr(
                "仅将内建屏幕背光调至 0%，GPU 渲染与远程桌面（VNC/屏幕共享）保持完全正常。\n\n随时按 Esc、⌘⌥B 或键盘亮度增键 (F2) 即可立即恢复亮度。",
                "Sets only the built-in display backlight to 0% while keeping GPU rendering and remote desktop active.\n\nPress Esc, ⌘⌥B, or the Brightness Up key (F2) at any time to restore."
            )
            alert.addButton(withTitle: ZtatL10n.tr("立即熄屏", "Enable Blackout"))
            alert.addButton(withTitle: ZtatL10n.tr("取消", "Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(true, forKey: PowerGuardDefaultsKey.hasShownBlackoutGuide)
        }

        // Automatically ensure idle keep-awake is active during blackout
        if !isIdleKeepAwakeActive {
            let exp: Date? = selectedDuration == .infinite ? nil : Date().addingTimeInterval(selectedDuration.rawValue)
            enableIdleKeepAwake(expiration: exp)
        }

        if DisplayBlackoutEngine.shared.enableBlackout() {
            isBlackoutActive = true
            installBlackoutRecoveryHooks()
            appendLog(ZtatL10n.tr("已开启物理熄屏挂机 (0% 背光，按 Esc/⌘⌥B/F2 恢复)", "Physical blackout active (press Esc/⌘⌥B/F2 to restore)"))
            showToast(ZtatL10n.tr("物理熄屏已开启 · 按 Esc 或 F2 恢复", "Blackout active · Esc or F2 to restore"))
        } else {
            appendLog(ZtatL10n.tr("无法调节当前显示器背光亮度", "Unable to adjust built-in display backlight"), isWarning: true)
            showToast(ZtatL10n.tr("当前显示器不支持背光控制", "Display backlight control unsupported"))
        }
        refreshTelemetry()
        publishSnapshot()
    }

    public func togglePasswordlessSudo() {
        guard !isBusy else { return }
        isBusy = true
        let currentlyReady = telemetry.isPasswordlessSudoReady
        Task { [weak self] in
            let res = currentlyReady
                ? await ClamshellSudoEngine.shared.removePasswordlessSudoers()
                : await ClamshellSudoEngine.shared.installPasswordlessSudoers()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                if res.success {
                    self.telemetry.isPasswordlessSudoReady = !currentlyReady
                    self.appendLog(
                        currentlyReady
                            ? ZtatL10n.tr("已移除免密 pmset 授权规则", "Removed passwordless pmset rule")
                            : ZtatL10n.tr("已配置最小权限免密 pmset 规则 (#uid)", "Installed least-privilege passwordless pmset rule (#uid)")
                    )
                    self.showToast(currentlyReady ? ZtatL10n.tr("已移除免密规则", "Passwordless rule removed") : ZtatL10n.tr("免密切换已就绪", "Passwordless switching ready"))
                } else {
                    self.appendLog(ZtatL10n.tr("免密规则操作失败：\(res.error ?? "")", "Sudoers update failed: \(res.error ?? "")"), isWarning: true)
                }
            }
        }
    }

    public func setDuration(_ duration: PowerGuardDuration) {
        selectedDuration = duration
        if isIdleKeepAwakeActive {
            let exp: Date? = duration == .infinite ? nil : Date().addingTimeInterval(duration.rawValue)
            scheduleExpiration(exp)
            publishSnapshot()
        }
    }

    public func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Internal Assertion & Event Handling

    private func enableIdleKeepAwake(expiration: Date?) {
        refreshIdleAssertions()
        scheduleExpiration(expiration)
        reconcileFramebufferTimer()
        appendLog(ZtatL10n.tr("已开启系统防休眠断言（\(selectedDuration.displayTitle)）", "Enabled idle sleep assertions (\(selectedDuration.displayTitle))"))
        publishSnapshot()
    }

    private func refreshIdleAssertions() {
        releaseIdleAssertions()
        var sysID: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "ztat PowerGuard System Keep-Awake" as CFString,
            &sysID
        ) == kIOReturnSuccess {
            systemSleepAssertionID = sysID
        }

        if !allowDisplaySleep {
            var dispID: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ztat PowerGuard Display Keep-Awake" as CFString,
                &dispID
            ) == kIOReturnSuccess {
                displaySleepAssertionID = dispID
            }
        }
        isIdleKeepAwakeActive = (systemSleepAssertionID != 0 || displaySleepAssertionID != 0)
    }

    private func releaseIdleAssertions() {
        if systemSleepAssertionID != 0 {
            IOPMAssertionRelease(systemSleepAssertionID)
            systemSleepAssertionID = 0
        }
        if displaySleepAssertionID != 0 {
            IOPMAssertionRelease(displaySleepAssertionID)
            displaySleepAssertionID = 0
        }
        isIdleKeepAwakeActive = false
    }

    private func scheduleExpiration(_ date: Date?) {
        expirationTimer?.invalidate()
        expirationTimer = nil
        expirationDate = date
        guard let date else { return }
        let t = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendLog(ZtatL10n.tr("定时保活已到期，自动恢复默认休眠", "Keep-awake timer expired; restoring default sleep"))
                self.disableAll()
            }
        }
        t.tolerance = 1.0
        RunLoop.main.add(t, forMode: .common)
        expirationTimer = t
    }

    private func reconcileFramebufferTimer() {
        framebufferGuardTimer?.invalidate()
        framebufferGuardTimer = nil
        guard isAnyGuardActive && keepFramebufferAwake else {
            DisplayBlackoutEngine.shared.releaseFramebufferWakeAssertion()
            return
        }
        // Lightweight 15s heartbeat (only while guard is active) to keep headless/clamshell framebuffer awake
        let t = Timer(timeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isAnyGuardActive, self.keepFramebufferAwake else { return }
                if self.telemetry.lidClosed || self.telemetry.displayAsleep || self.isBlackoutActive {
                    DisplayBlackoutEngine.shared.renewFramebufferWakeAssertion()
                }
            }
        }
        t.tolerance = 3.0
        RunLoop.main.add(t, forMode: .common)
        framebufferGuardTimer = t
    }

    private func handleHardwareEvent() {
        let wasLidClosed = telemetry.lidClosed
        refreshTelemetry()

        // 1. Auto-dim built-in screen on lid close while clamshell lock is active
        if autoDimOnLidClose && isClamshellLocked {
            if telemetry.lidClosed && !wasLidClosed && !isBlackoutActive {
                if DisplayBlackoutEngine.shared.enableBlackout() {
                    didAutoDimForLid = true
                    appendLog(ZtatL10n.tr("检测到合盖，已自动关闭内建屏幕背光", "Lid closed; dimmed built-in backlight"))
                }
            } else if !telemetry.lidClosed && wasLidClosed && didAutoDimForLid {
                didAutoDimForLid = false
                _ = DisplayBlackoutEngine.shared.disableBlackout(retryOnFailure: true)
                appendLog(ZtatL10n.tr("检测到开盖，已自动恢复内建屏幕背光", "Lid opened; restored built-in backlight"))
            }
        }

        // 2. Low-battery anti-overheat & anti-drain full cutoff
        if lowBatteryAutoRestore,
           isAnyGuardActive,
           !telemetry.isOnACPower,
           !telemetry.isCharging,
           let pct = telemetry.batteryPercentage,
           pct <= lowBatteryThreshold {
            appendLog(
                ZtatL10n.tr("电池电量低至 \(pct)%（阈值 \(lowBatteryThreshold)%），自动解除全部保活并允许休眠",
                           "Battery reached \(pct)% (cutoff \(lowBatteryThreshold)%); disabling all keep-awake"),
                isWarning: true
            )
            disableAll()
        }
    }

    public func refreshTelemetry() {
        let sudoReady = ClamshellSudoEngine.shared.isPasswordlessSudoReadyCached()
        let next = HardwarePowerProbe.shared.snapshot(passwordlessSudoReady: sudoReady)
        telemetry = next
        isClamshellLocked = next.sleepDisabledKernel

        if isBlackoutActive && DisplayBlackoutEngine.shared.reconcileExternalBrightnessChange() {
            isBlackoutActive = false
            removeBlackoutRecoveryHooks()
            appendLog(ZtatL10n.tr("检测到手动调亮屏幕，已自动退出熄屏状态", "Manual brightness increase detected; exited blackout"))
        }
        publishSnapshot()
    }

    private func recoverFromUncleanExitIfNeeded() {
        if DisplayBlackoutEngine.shared.recoverFromCrashIfNeeded() {
            appendLog(ZtatL10n.tr("检测到上次异常退出处于熄屏状态，已自动恢复屏幕亮度", "Recovered built-in brightness after unclean exit"), isWarning: true)
        }
        if UserDefaults.standard.bool(forKey: PowerGuardDefaultsKey.sleepDisabledOwned) {
            let root = HardwarePowerProbe.shared.readRootDomainState()
            if root.sleepDisabled {
                Task { [weak self] in
                    if ClamshellSudoEngine.shared.probePasswordlessSudoSync() {
                        let res = await ClamshellSudoEngine.shared.setSleepDisabled(false)
                        if res.success {
                            await MainActor.run { [weak self] in
                                self?.appendLog(ZtatL10n.tr("已从上次异常退出自动恢复系统默认合盖休眠", "Recovered default clamshell sleep after unclean exit"), isWarning: true)
                                self?.refreshTelemetry()
                            }
                        }
                    }
                }
            } else {
                UserDefaults.standard.removeObject(forKey: PowerGuardDefaultsKey.sleepDisabledOwned)
            }
        }
    }

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshTelemetry()
                    if self.isAnyGuardActive && self.keepFramebufferAwake {
                        DisplayBlackoutEngine.shared.renewFramebufferWakeAssertion()
                    }
                }
            }
        )
        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshTelemetry()
                }
            }
        )
        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stopForTermination()
                }
            }
        )
    }

    // MARK: - Unfocused Blackout Recovery (Local Esc + Carbon ⌘⌥B Hotkey, zero Accessibility permission needed)

    private func installBlackoutRecoveryHooks() {
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { // Escape
                    Task { @MainActor [weak self] in
                        if self?.isBlackoutActive == true {
                            self?.toggleBlackoutMode()
                        }
                    }
                    return nil
                }
                return event
            }
        }

        if blackoutHotKeyRef == nil {
            if !Self.hotKeyHandlerInstalled {
                var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(
                    GetApplicationEventTarget(),
                    { _, event, _ -> OSStatus in
                        var hkID = EventHotKeyID()
                        GetEventParameter(
                            event,
                            EventParamName(kEventParamDirectObject),
                            EventParamType(typeEventHotKeyID),
                            nil,
                            MemoryLayout<EventHotKeyID>.size,
                            nil,
                            &hkID
                        )
                        if hkID.signature == 0x5A545047 && hkID.id == 1 { // 'ZTPG'
                            Task { @MainActor in
                                if PowerGuardCoordinator.shared.isBlackoutActive {
                                    PowerGuardCoordinator.shared.toggleBlackoutMode()
                                }
                            }
                        }
                        return noErr
                    },
                    1,
                    &eventType,
                    nil,
                    nil
                )
                Self.hotKeyHandlerInstalled = true
            }
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: 0x5A545047, id: 1)
            // ⌘⌥B works globally without Accessibility permission
            if RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey), hkID, GetApplicationEventTarget(), 0, &ref) == noErr {
                blackoutHotKeyRef = ref
            }
        }
    }

    private func removeBlackoutRecoveryHooks() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let ref = blackoutHotKeyRef {
            UnregisterEventHotKey(ref)
            blackoutHotKeyRef = nil
        }
    }

    private func publishSnapshot() {
        ZtatPowerGuardRegistry.shared.publish(currentSnapshot)
    }

    private func appendLog(_ message: String, isWarning: Bool = false) {
        logs.insert(PowerGuardLogEntry(message: message, isWarning: isWarning), at: 0)
        if logs.count > 60 {
            logs.removeLast(logs.count - 60)
        }
    }

    private func showToast(_ text: String) {
        toastDismissTask?.cancel()
        toastMessage = text
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }
}
