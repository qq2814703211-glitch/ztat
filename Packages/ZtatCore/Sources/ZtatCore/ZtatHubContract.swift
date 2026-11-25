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
    case statusTrio
    case powerGuard
    case stats
    case toolbox

    public var id: String { rawValue }
}

public extension Notification.Name {
    static let ztatOpenHubTab = Notification.Name("dev.ztat.openHubTab")
    static let ztatOpenSettings = Notification.Name("dev.ztat.openSettings")
    static let ztatPowerGuardDidChange = Notification.Name("dev.ztat.powerGuardDidChange")
    static let ztatStatsDidChange = Notification.Name("dev.ztat.statsDidChange")
    static let ztatVorssaintMicMuteDidChange = Notification.Name("dev.ztat.vorssaintMicMuteDidChange")
}

/// Cross-module read-only snapshot of ZtatPowerGuard so Vorssaint (Dynamic Island),
/// Status Trio (icon/right-click), and ZtatApp header pills stay synchronized without circular dependencies.
public struct ZtatPowerGuardSnapshot: Equatable, Sendable {
    public var isActive: Bool
    public var isIdleKeepAwakeActive: Bool
    public var isClamshellLocked: Bool
    public var isBlackoutActive: Bool
    public var isLidClosed: Bool
    public var isDisplayAsleep: Bool
    public var isOnACPower: Bool
    public var batteryPercentage: Int?
    public var remainingSeconds: TimeInterval?
    public var expirationDate: Date?
    public var summaryLabel: String

    public init(
        isActive: Bool = false,
        isIdleKeepAwakeActive: Bool = false,
        isClamshellLocked: Bool = false,
        isBlackoutActive: Bool = false,
        isLidClosed: Bool = false,
        isDisplayAsleep: Bool = false,
        isOnACPower: Bool = true,
        batteryPercentage: Int? = nil,
        remainingSeconds: TimeInterval? = nil,
        expirationDate: Date? = nil,
        summaryLabel: String = ""
    ) {
        self.isActive = isActive
        self.isIdleKeepAwakeActive = isIdleKeepAwakeActive
        self.isClamshellLocked = isClamshellLocked
        self.isBlackoutActive = isBlackoutActive
        self.isLidClosed = isLidClosed
        self.isDisplayAsleep = isDisplayAsleep
        self.isOnACPower = isOnACPower
        self.batteryPercentage = batteryPercentage
        self.remainingSeconds = remainingSeconds
        self.expirationDate = expirationDate
        self.summaryLabel = summaryLabel
    }
}

@MainActor
public protocol ZtatPowerGuardControlling: AnyObject {
    var currentSnapshot: ZtatPowerGuardSnapshot { get }
    func toggleRemoteReadyMode()
    func toggleBlackoutMode()
    func activateForDuration(seconds: TimeInterval?)
    func disableAll()
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

    public func toggleBlackoutMode() {
        controller?.toggleBlackoutMode()
    }

    public func activateForDuration(seconds: TimeInterval?) {
        controller?.activateForDuration(seconds: seconds)
    }

    public func disableAll() {
        controller?.disableAll()
    }
}
