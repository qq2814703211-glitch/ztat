// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import Foundation

/// Hub tabs inside ztat's unified menu bar Liquid Glass control center.
public enum ZtatHubTab: String, CaseIterable, Identifiable, Sendable {
    case status
    case powerGuard
    case toolbox
    case monitor

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .status: return ZtatL10n.tr("状态", "Status")
        case .powerGuard: return ZtatL10n.tr("保活", "Guard")
        case .toolbox: return ZtatL10n.tr("工具箱", "Tools")
        case .monitor: return ZtatL10n.tr("监控", "Stats")
        }
    }

    public var symbolName: String {
        switch self {
        case .status: return "dot.radiowaves.left.and.right"
        case .powerGuard: return "bolt.shield.fill"
        case .toolbox: return "square.grid.2x2.fill"
        case .monitor: return "gauge.with.dots.needle.67percent"
        }
    }
}

public enum ZtatSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case permissions
    case taskManager
    case powerGuard
    case island
    case cleaner
    case statusTrio
    case stats
    case toolbox

    public var id: String { rawValue }
}

/// Fine-grained deep-link route into ztat's single unified Settings window.
public enum ZtatSettingsRoute: Equatable, Hashable, Sendable {
    case general
    case permissions
    case taskManager
    case powerGuard
    case island(sectionID: String? = nil)
    case cleaner(sectionID: String? = nil)
    case statusTrio(sectionID: String? = nil)
    case stats(target: String? = nil)
    case toolbox(itemID: String? = nil)

    public init(section: ZtatSettingsSection) {
        switch section {
        case .general: self = .general
        case .permissions: self = .permissions
        case .taskManager: self = .taskManager
        case .powerGuard: self = .powerGuard
        case .island: self = .island(sectionID: nil)
        case .cleaner: self = .cleaner(sectionID: nil)
        case .statusTrio: self = .statusTrio(sectionID: nil)
        case .stats: self = .stats(target: nil)
        case .toolbox: self = .toolbox(itemID: nil)
        }
    }
}

public extension Notification.Name {
    static let ztatOpenHubTab = Notification.Name("dev.ztat.openHubTab")
    static let ztatOpenSettings = Notification.Name("dev.ztat.openSettings")
    static let ztatOpenAppUninstaller = Notification.Name("dev.ztat.openAppUninstaller")
    static let ztatToggleTaskManager = Notification.Name("dev.ztat.toggleTaskManager")
    static let ztatOpenTaskManager = Notification.Name("dev.ztat.openTaskManager")
    static let ztatHubPanelVisibilityDidChange = Notification.Name("dev.ztat.hubPanelVisibilityDidChange")
    static let ztatPowerGuardDidChange = Notification.Name("dev.ztat.powerGuardDidChange")
    static let ztatStatsDidChange = Notification.Name("dev.ztat.statsDidChange")
    static let ztatIslandDidChange = Notification.Name("dev.ztat.islandDidChange")
    static let ztatCleanerDidChange = Notification.Name("dev.ztat.cleanerDidChange")
    static let ztatMicMuteDidChange = Notification.Name("dev.ztat.micMuteDidChange")
    static let ztatLanguageDidChange = Notification.Name("dev.ztat.languageDidChange")
    static let ztatAppearanceDidChange = Notification.Name("dev.ztat.appearanceDidChange")
}

/// Cross-module read-only snapshot of ZtatPowerGuard so Dynamic Island,
/// Status Hub (Power Modes / Quick Actions / Battery), and ZtatApp stay synchronized without circular dependencies.
public struct ZtatPowerGuardSnapshot: Equatable, Sendable {
    public var isActive: Bool
    public var isIdleKeepAwakeActive: Bool
    public var isClamshellLocked: Bool
    public var isBlackoutActive: Bool
    public var isLidClosed: Bool
    public var isDisplayAsleep: Bool
    public var isOnACPower: Bool
    public var isCharging: Bool
    public var batteryPercentage: Int?
    public var remainingSeconds: TimeInterval?
    public var expirationDate: Date?
    public var summaryLabel: String
    public var isLowPowerMode: Bool
    public var isHighPowerMode: Bool
    public var supportsHighPowerMode: Bool
    public var isPasswordlessSudoReady: Bool

    public init(
        isActive: Bool = false,
        isIdleKeepAwakeActive: Bool = false,
        isClamshellLocked: Bool = false,
        isBlackoutActive: Bool = false,
        isLidClosed: Bool = false,
        isDisplayAsleep: Bool = false,
        isOnACPower: Bool = true,
        isCharging: Bool = false,
        batteryPercentage: Int? = nil,
        remainingSeconds: TimeInterval? = nil,
        expirationDate: Date? = nil,
        summaryLabel: String = "",
        isLowPowerMode: Bool = false,
        isHighPowerMode: Bool = false,
        supportsHighPowerMode: Bool = false,
        isPasswordlessSudoReady: Bool = false
    ) {
        self.isActive = isActive
        self.isIdleKeepAwakeActive = isIdleKeepAwakeActive
        self.isClamshellLocked = isClamshellLocked
        self.isBlackoutActive = isBlackoutActive
        self.isLidClosed = isLidClosed
        self.isDisplayAsleep = isDisplayAsleep
        self.isOnACPower = isOnACPower
        self.isCharging = isCharging
        self.batteryPercentage = batteryPercentage
        self.remainingSeconds = remainingSeconds
        self.expirationDate = expirationDate
        self.summaryLabel = summaryLabel
        self.isLowPowerMode = isLowPowerMode
        self.isHighPowerMode = isHighPowerMode
        self.supportsHighPowerMode = supportsHighPowerMode
        self.isPasswordlessSudoReady = isPasswordlessSudoReady
    }
}

@MainActor
public protocol ZtatPowerGuardControlling: AnyObject {
    var currentSnapshot: ZtatPowerGuardSnapshot { get }
    func toggleRemoteReadyMode()
    func toggleIdleKeepAwake()
    func toggleClamshellLock()
    func toggleBlackoutMode()
    func activateForDuration(seconds: TimeInterval?)
    func disableAll()
    func refreshPowerModes() async
    func readLowPowerMode() async -> Bool
    func readHighPowerModeSupport() async -> Bool
    func readHighPowerMode() async -> Bool
    func setLowPowerMode(_ enabled: Bool, allowInteractivePrompt: Bool) async -> (success: Bool, observed: Bool, error: String?)
    func setHighPowerMode(_ enabled: Bool, allowInteractivePrompt: Bool) async -> (success: Bool, observed: Bool, error: String?)
    func installPasswordlessSudoers() async -> (success: Bool, error: String?)
}

@MainActor
public final class ZtatPowerGuardRegistry: ObservableObject {
    public static let shared = ZtatPowerGuardRegistry()

    @Published public private(set) var snapshot = ZtatPowerGuardSnapshot()
    private weak var controller: (any ZtatPowerGuardControlling)?

    private init() {}

    public func register(_ controller: any ZtatPowerGuardControlling) {
        self.controller = controller
        self.snapshot = controller.currentSnapshot
    }

    public func publish(_ snapshot: ZtatPowerGuardSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        NotificationCenter.default.post(name: .ztatPowerGuardDidChange, object: nil)
    }

    public func toggleRemoteReadyMode() {
        controller?.toggleRemoteReadyMode()
    }

    public func toggleIdleKeepAwake() {
        controller?.toggleIdleKeepAwake()
    }

    public func toggleClamshellLock() {
        controller?.toggleClamshellLock()
    }

    public func toggleBlackoutMode() {
        controller?.toggleBlackoutMode()
    }

    public func activateForDuration(seconds: TimeInterval?) {
        controller?.activateForDuration(seconds: seconds)
    }

    public func disableAll() {
        controller?.disableAll()
    }

    public func refreshPowerModes() async {
        await controller?.refreshPowerModes()
    }

    public func readLowPowerMode() async -> Bool {
        if let controller {
            return await controller.readLowPowerMode()
        }
        return ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    public func readHighPowerModeSupport() async -> Bool {
        if let controller {
            return await controller.readHighPowerModeSupport()
        }
        return false
    }

    public func readHighPowerMode() async -> Bool {
        if let controller {
            return await controller.readHighPowerMode()
        }
        return false
    }

    public func setLowPowerMode(_ enabled: Bool, allowInteractivePrompt: Bool = true) async -> (success: Bool, observed: Bool, error: String?) {
        guard let controller else {
            return (false, ProcessInfo.processInfo.isLowPowerModeEnabled, "PowerGuard engine not initialized")
        }
        return await controller.setLowPowerMode(enabled, allowInteractivePrompt: allowInteractivePrompt)
    }

    public func setHighPowerMode(_ enabled: Bool, allowInteractivePrompt: Bool = true) async -> (success: Bool, observed: Bool, error: String?) {
        guard let controller else {
            return (false, false, "PowerGuard engine not initialized")
        }
        return await controller.setHighPowerMode(enabled, allowInteractivePrompt: allowInteractivePrompt)
    }

    public func installPasswordlessSudoers() async -> (success: Bool, error: String?) {
        guard let controller else {
            return (false, "PowerGuard engine not initialized")
        }
        return await controller.installPasswordlessSudoers()
    }
}
