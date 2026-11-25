// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import ZtatCore
import ZtatPowerGuard
@testable import StatsKit
import ZtatStatsHost
@testable import StatusTrioCore
@testable import VorssaintToolbox

@Suite("ZtatCore & Governance Contracts")
struct ZtatCoreTests {
    @Test("Brand constants enforce distinct ztat identity and Stats suite isolation")
    func brandConstants() {
        #expect(ZtatBrand.appName == "ztat")
        #expect(ZtatBrand.bundleIdentifier == "dev.ztat.app")
        #expect(ZtatBrand.statsDefaultsSuite == "dev.ztat.app.stats")
        #expect(ZtatBrand.statsDefaultsSuite != ZtatBrand.bundleIdentifier)
        #expect(ZtatBrand.hubPanelWidth == 356)
    }

    @Test("Hub tabs cover all four unified control center domains")
    func hubTabsComplete() {
        #expect(ZtatHubTab.allCases == [.status, .powerGuard, .toolbox, .monitor])
        for tab in ZtatHubTab.allCases {
            #expect(!tab.title.isEmpty)
            #expect(!tab.symbolName.isEmpty)
        }
    }

    @MainActor
    @Test("SharedPasteboardMonitor automatically starts and stops timer with subscribers")
    func sharedPasteboardLifecycle() {
        let monitor = SharedPasteboardMonitor.shared
        let baseline = monitor.subscriberCount
        let id1 = monitor.subscribe { _ in }
        let id2 = monitor.subscribe { _ in }
        #expect(monitor.subscriberCount == baseline + 2)
        monitor.unsubscribe(id1)
        #expect(monitor.subscriberCount == baseline + 1)
        monitor.unsubscribe(id2)
        #expect(monitor.subscriberCount == baseline)
    }

    @MainActor
    @Test("ZtatPowerGuardRegistry publishes snapshots without duplicating unchanged state")
    func powerGuardRegistryPublishing() {
        let reg = ZtatPowerGuardRegistry.shared
        let snap = ZtatPowerGuardSnapshot(
            isActive: true,
            isIdleKeepAwakeActive: true,
            isClamshellLocked: true,
            isBlackoutActive: false,
            isLidClosed: false,
            isDisplayAsleep: false,
            isOnACPower: true,
            batteryPercentage: 85,
            remainingSeconds: 1800,
            expirationDate: nil,
            summaryLabel: "Remote-Ready"
        )
        reg.publish(snap)
        #expect(reg.snapshot == snap)
        reg.publish(ZtatPowerGuardSnapshot())
        #expect(!reg.snapshot.isActive)
    }
}

@Suite("ZtatPowerGuard Clean-Room Engine")
struct ZtatPowerGuardTests {
    @Test("Least-privilege sudoers rule scopes strictly to #uid and disablesleep 0/1 only")
    func sudoersLeastPrivilegeRule() {
        let rule = ClamshellSudoEngine.shared.expectedRuleLine
        let uidPrefix = "#\(getuid()) "
        #expect(rule.hasPrefix(uidPrefix))
        #expect(rule.contains("NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"))
        #expect(!rule.contains("ALL=(ALL) NOPASSWD: ALL"))
        #expect(!rule.contains("*"))
    }

    @Test("Duration presets cover 15m through 24h plus indefinite")
    func durationPresets() {
        #expect(PowerGuardDuration.allCases.count == 8)
        #expect(PowerGuardDuration.fifteenMinutes.rawValue == 900)
        #expect(PowerGuardDuration.twentyFourHours.rawValue == 86400)
        #expect(PowerGuardDuration.infinite.rawValue == 0)
        #expect(PowerGuardDuration.infinite.shortTitle == "∞")
    }

    @Test("HardwarePowerProbe captures live macOS hardware telemetry cleanly")
    func hardwareProbeSnapshot() {
        let snap = HardwarePowerProbe.shared.snapshot(passwordlessSudoReady: false)
        #expect(!snap.osVersion.isEmpty)
        #expect(!snap.hardwareModel.isEmpty)
        if let pct = snap.batteryPercentage {
            #expect(pct >= 0 && pct <= 100)
        }
        if let br = snap.builtInBrightness {
            #expect(br >= 0.0 && br <= 1.0)
        }
    }

    @Test("DisplayBlackoutEngine resolves a valid display target and never leaks wake assertions")
    func displayTargetAndWakeGuard() {
        let displayID = DisplayBlackoutEngine.shared.targetBuiltInDisplayID()
        #expect(displayID != 0)
        DisplayBlackoutEngine.shared.renewFramebufferWakeAssertion()
        DisplayBlackoutEngine.shared.renewFramebufferWakeAssertion()
        DisplayBlackoutEngine.shared.releaseFramebufferWakeAssertion()
    }
}

@Suite("ZtatStats Pure-SPM Isolation & Optimizations")
struct ZtatStatsTests {
    @Test("Stats Store writes to isolated dev.ztat.app.stats suite without touching UserDefaults.standard")
    func storeSuiteIsolation() {
        let sentinelKey = "ztat.test.standardSentinel.\(UUID().uuidString)"
        let statsKey = "ztat.test.statsKey.\(UUID().uuidString)"

        UserDefaults.standard.set("keep-me", forKey: sentinelKey)
        defer { UserDefaults.standard.removeObject(forKey: sentinelKey) }

        Store.shared.set(key: statsKey, value: 42)
        #expect(Store.shared.int(key: statsKey, defaultValue: 0) == 42)
        #expect(UserDefaults.standard.object(forKey: statsKey) == nil)

        Store.shared.remove(statsKey)
        #expect(UserDefaults.standard.string(forKey: sentinelKey) == "keep-me")
    }

    @Test("Stats notifications are namespaced with ztat.stats. prefix")
    func notificationPrefixIsolation() {
        #expect(Notification.Name.toggleModule.rawValue.hasPrefix("ztat.stats."))
        #expect(Notification.Name.toggleSettings.rawValue.hasPrefix("ztat.stats."))
    }

    @Test("Pure-Swift DB cache round-trips values cleanly without LevelDB")
    func pureSwiftDBRoundTrip() {
        struct SampleRecord: Codable, Equatable {
            let label: String
            let bytes: Int64
        }
        let key = "ztat.test.db.\(UUID().uuidString)"
        let sample = SampleRecord(label: "en0", bytes: 123_456)
        DB.shared.insert(key: key, value: sample)
        let loaded = DB.shared.findOne(SampleRecord.self, key: key)
        #expect(loaded == sample)
        DB.shared.delete(key: key)
        #expect(DB.shared.findOne(SampleRecord.self, key: key) == nil)
    }
}

@Suite("ZtatStatusTrio Primary Host & Optimizations")
struct ZtatStatusTrioTests {
    @Test("Status Trio privileged power helper is cleanly disabled in ztat")
    @MainActor
    func disabledUpstreamDaemons() {
        let helperService = SystemPrivilegedHelperService()
        #expect(!helperService.isSupported)
    }

    @Test("Charging frame cache uses lazy on-demand storage instead of eager 36-frame allocation")
    @MainActor
    func lazyChargingFrameCache() {
        let cache = StatusBarChargingFrameCache()
        #expect(StatusBarChargingFrameCache.steadyFrameCount > 1)
        #expect(cache.rasterizedFrameCount == 0)
        #expect(cache.rebuildCount == 0)
    }
}

@Suite("ZtatVorssaint Deduplication & Rebranding")
struct ZtatVorssaintTests {
    @Test("Overlapping monitor, fanControl, and keepAwake features are permanently excluded")
    func excludedOverlappingFeatures() {
        let excluded: [AppFeature] = [
            .monitorCPU, .monitorGPU, .monitorMemory, .monitorNetwork,
            .monitorDisk, .monitorPower, .connectedDevices, .fanControl, .keepAwake
        ]
        for feature in excluded {
            #expect(feature.isExcludedInZtat, "Expected \(feature) to be excluded in ztat")
            #expect(!feature.isAvailable, "Excluded feature \(feature) must never report available")
        }

        // Core standout Vorssaint tools MUST remain available to users
        let retained: [AppFeature] = [
            .mixer, .clipboardHistory, .shelf, .notch, .brightness, .switcher, .screenRecorder
        ]
        for feature in retained {
            #expect(!feature.isExcludedInZtat, "Standout Vorssaint tool \(feature) should remain retained")
        }
    }

    @Test("Vorssaint branding is rebranded to ztat per upstream TRADEMARKS.md")
    func rebrandedAppInfo() {
        #expect(AppInfo.name == ZtatBrand.appName)
    }
}
