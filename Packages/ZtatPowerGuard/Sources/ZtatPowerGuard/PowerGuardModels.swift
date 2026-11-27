// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ZtatCore

public enum PowerGuardDuration: TimeInterval, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case fourHours = 14400
    case eightHours = 28800
    case twentyFourHours = 86400
    case infinite = 0

    public var id: TimeInterval { rawValue }

    public var shortTitle: String {
        switch self {
        case .fifteenMinutes: return "15m"
        case .thirtyMinutes: return "30m"
        case .oneHour: return "1h"
        case .twoHours: return "2h"
        case .fourHours: return "4h"
        case .eightHours: return "8h"
        case .twentyFourHours: return "24h"
        case .infinite: return "∞"
        }
    }

    public var displayTitle: String {
        switch self {
        case .fifteenMinutes: return ZtatL10n.tr("15 分钟", "15 min")
        case .thirtyMinutes: return ZtatL10n.tr("30 分钟", "30 min")
        case .oneHour: return ZtatL10n.tr("1 小时", "1 hour")
        case .twoHours: return ZtatL10n.tr("2 小时", "2 hours")
        case .fourHours: return ZtatL10n.tr("4 小时", "4 hours")
        case .eightHours: return ZtatL10n.tr("8 小时", "8 hours")
        case .twentyFourHours: return ZtatL10n.tr("24 小时", "24 hours")
        case .infinite: return ZtatL10n.tr("不限时", "Indefinite")
        }
    }
}

public struct PowerGuardTelemetry: Equatable, Sendable {
    public var lidClosed: Bool = false
    public var sleepDisabledKernel: Bool = false
    public var displayAsleep: Bool = false
    public var isOnACPower: Bool = true
    public var batteryPercentage: Int? = nil
    public var isCharging: Bool = false
    public var builtInBrightness: Float? = nil
    public var isPasswordlessSudoReady: Bool = false
    public var isClamshellSudoLegacyOnly: Bool = false
    public var isLowPowerMode: Bool = false
    public var isHighPowerMode: Bool = false
    public var supportsHighPowerMode: Bool = false
    public var hardwareModel: String = ""
    public var osVersion: String = ""

    public init() {}
}

public struct PowerGuardLogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let message: String
    public let isWarning: Bool

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public init(id: UUID = UUID(), timestamp: Date = Date(), message: String, isWarning: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
        self.isWarning = isWarning
    }

    public var formattedTime: String {
        Self.formatter.string(from: timestamp)
    }
}

public enum PowerGuardDefaultsKey {
    private static let p = ZtatBrand.powerGuardDefaultsPrefix
    public static let selectedDuration = p + "selectedDuration"
    public static let keepFramebufferAwake = p + "keepFramebufferAwake"
    public static let allowDisplaySleep = p + "allowDisplaySleep"
    public static let autoDimOnLidClose = p + "autoDimOnLidClose"
    public static let lowBatteryAutoRestore = p + "lowBatteryAutoRestore"
    public static let lowBatteryThreshold = p + "lowBatteryThreshold"
    public static let restoreSleepOnQuit = p + "restoreSleepOnQuit"
    public static let hasShownBlackoutGuide = p + "hasShownBlackoutGuide"
    public static let sleepDisabledOwned = p + "sleepDisabledOwned"
    public static let savedBlackoutBrightness = p + "savedBlackoutBrightness"

    static let allKeys: [String] = [
        selectedDuration, keepFramebufferAwake, allowDisplaySleep, autoDimOnLidClose,
        lowBatteryAutoRestore, lowBatteryThreshold, restoreSleepOnQuit, hasShownBlackoutGuide,
        sleepDisabledOwned, savedBlackoutBrightness,
    ]
}

/// Shared UserDefaults suite used by BOTH `ztat.app` and `ztat-hold` CLI so crash recovery
/// (`sleepDisabledOwned`, `savedBlackoutBrightness`) and settings remain consistent across binaries.
public enum PowerGuardDefaults {
    /// Apple documents `UserDefaults` as thread-safe; mark `nonisolated(unsafe)` for Swift 6 strict concurrency.
    public nonisolated(unsafe) static let store: UserDefaults = {
        let suite = UserDefaults(suiteName: ZtatBrand.powerGuardDefaultsSuite) ?? .standard
        // One-time migration from legacy UserDefaults.standard keys when suite has no entries yet.
        let migratedKey = ZtatBrand.powerGuardDefaultsPrefix + "migratedToSuite"
        if !suite.bool(forKey: migratedKey) {
            let legacy = UserDefaults.standard
            for key in PowerGuardDefaultsKey.allKeys {
                if suite.object(forKey: key) == nil, let val = legacy.object(forKey: key) {
                    suite.set(val, forKey: key)
                }
            }
            suite.set(true, forKey: migratedKey)
        }
        return suite
    }()
}
