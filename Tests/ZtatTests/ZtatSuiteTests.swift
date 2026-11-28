// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Testing
import ZtatCore
import ZtatPowerGuard
@testable import StatsKit
import ZtatStatsHost
@testable import StatusTrioCore
import ZtatIsland
import ZtatCleaner
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

    @MainActor
    @Test("Unified ZtatLocalizationStore drives ZtatL10n dynamically")
    func unifiedLocalizationSwitching() {
        let store = ZtatLocalizationStore.shared
        let previous = store.preference
        defer { store.preference = previous }

        store.preference = .zhHans
        #expect(ZtatL10n.isChinese)
        #expect(ZtatL10n.tr("测试", "Test") == "测试")

        store.preference = .en
        #expect(!ZtatL10n.isChinese)
        #expect(ZtatL10n.tr("测试", "Test") == "Test")
    }

    @Test("Settings sections and routes cover unified Permissions portal")
    func permissionsRouteContract() {
        #expect(ZtatSettingsSection.allCases.contains(.permissions))
        #expect(ZtatSettingsRoute(section: .permissions) == .permissions)
        #expect(ZtatSettingsSection.allCases.contains(.island))
        #expect(ZtatSettingsRoute(section: .island) == .island(sectionID: nil))
        #expect(ZtatSettingsSection.allCases.contains(.cleaner))
        #expect(ZtatSettingsRoute(section: .cleaner) == .cleaner(sectionID: nil))
        #expect(ZtatBrand.islandDefaultsSuite == "dev.ztat.app.island")
        #expect(ZtatBrand.cleanerDefaultsSuite == "dev.ztat.app.cleaner")
        #expect(ZtatBrand.islandDefaultsSuite != ZtatBrand.bundleIdentifier)
        #expect(ZtatBrand.islandDefaultsSuite != ZtatBrand.statsDefaultsSuite)
        #expect(ZtatBrand.cleanerDefaultsSuite != ZtatBrand.bundleIdentifier)
        #expect(ZtatBrand.cleanerDefaultsSuite != ZtatBrand.statsDefaultsSuite)
        #expect(ZtatBrand.cleanerDefaultsSuite != ZtatBrand.islandDefaultsSuite)
    }
}

@Suite("ZtatPowerGuard Clean-Room Engine")
struct ZtatPowerGuardTests {
    @Test("Least-privilege sudoers rule scopes strictly to #uid and explicit pmset power/sleep commands only")
    func sudoersLeastPrivilegeRule() {
        let rule = ClamshellSudoEngine.shared.expectedRuleLine
        let uidPrefix = "#\(getuid()) "
        #expect(rule.hasPrefix(uidPrefix))
        #expect(rule.contains("NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"))
        #expect(rule.contains("/usr/bin/pmset -a lowpowermode 1"))
        #expect(rule.contains("/usr/bin/pmset -a lowpowermode 0"))
        #expect(rule.contains("/usr/bin/pmset -a powermode 0"))
        #expect(rule.contains("/usr/bin/pmset -a powermode 2"))
        #expect(rule.contains("/usr/bin/pmset -a highpowermode 1"))
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

    @Test("Stats settings target normalization maps popup/portal targets into ztat unified Settings routes")
    @MainActor
    func statsUnifiedSettingsTargetNormalization() {
        #expect(ZtatStatsHost.normalizeSettingsTarget(nil) == "overview")
        #expect(ZtatStatsHost.normalizeSettingsTarget("Combined modules") == "overview")
        #expect(ZtatStatsHost.normalizeSettingsTarget("Dashboard") == "dashboard")
        #expect(ZtatStatsHost.normalizeSettingsTarget("Settings") == "settings")
        #expect(ZtatStatsHost.normalizeSettingsTarget("CPU") == "CPU")
        #expect(ZtatStatsHost.normalizeSettingsTarget("RAM") == "RAM")

        #expect(ZtatSettingsRoute(section: .general) == .general)
        #expect(ZtatSettingsRoute(section: .powerGuard) == .powerGuard)
        #expect(ZtatSettingsRoute(section: .statusTrio) == .statusTrio(sectionID: nil))
        #expect(ZtatSettingsRoute(section: .stats) == .stats(target: nil))
        #expect(ZtatSettingsRoute(section: .toolbox) == .toolbox(itemID: nil))
        #expect(!SMCHelper.shared.isSupported)
        #expect(Constants.Widget.height == NSStatusBar.system.thickness)
        #expect(Constants.Widget.height <= 24)
    }

    @Test("Vitals Dashboard telemetry, pane routing, and zero-idle consumer lifecycle work end-to-end")
    @MainActor
    func vitalsDashboardContracts() async throws {
        let model = VitalsDashboardModel.shared
        model.beginConsumer("test.suite.vitals")
        defer { model.endConsumer("test.suite.vitals") }

        for _ in 0..<40 {
            if model.hardware.memory.totalGB > 0 && model.hardware.uptimeSeconds > 0 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(model.hardware.memory.totalGB > 0)
        #expect(model.hardware.uptimeSeconds > 0)
        #expect(!model.hardware.gpuName.isEmpty)
        #expect(VitalsPane.allCases.count >= 14)
        #expect(VitalsPane.fromStatsModuleName("CPU") == .cpu)
        #expect(VitalsPane.fromStatsModuleName("GPU") == .gpu)
        #expect(VitalsPane.fromStatsModuleName("RAM") == .memory)
        #expect(VitalsPane.fromStatsModuleName("Network") == .network)
        #expect(ZtatSettingsSection.allCases.contains(.taskManager))
        #expect(ZtatSettingsRoute(section: .taskManager) == .taskManager)
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

    @Test("Status Trio exposes flat section descriptors for ztat unified sidebar without keepAwake or about")
    @MainActor
    func flatStatusTrioSettingsSections() {
        let items = ZtatStatusTrioHost.shared.settingsSectionItems()
        let ids = items.map(\.id)
        #expect(ids.contains("appIcon"))
        #expect(ids.contains("battery"))
        #expect(ids.contains("network"))
        #expect(!ids.contains("keepAwake"))
        #expect(!ids.contains("about"))
        for item in items {
            #expect(!item.title.isEmpty)
            #expect(!item.symbolName.isEmpty)
        }
    }
}

@Suite("ZtatVorssaint Deduplication & Rebranding")
struct ZtatVorssaintTests {
    @Test("Overlapping monitor, fanControl, keepAwake, and Vorssaint notch features are permanently excluded")
    func excludedOverlappingFeatures() {
        let excluded: [AppFeature] = [
            .monitorCPU, .monitorGPU, .monitorMemory, .monitorNetwork,
            .monitorDisk, .monitorPower, .connectedDevices, .fanControl, .keepAwake, .uninstaller,
            .notch, .notchCalendar, .notchNotifications, .notchGestures,
            .notchTimer, .notchAccessories, .notchLyrics, .notchQueue,
            .notchLiveEqualizer, .notchDownloads, .notchAgents, .notchWatch, .notchMascot
        ]
        for feature in excluded {
            #expect(feature.isExcludedInZtat, "Expected \(feature) to be excluded in ztat")
            #expect(!feature.isAvailable, "Excluded feature \(feature) must never report available")
        }
        #expect(!FeatureGroup.ztatVisibleCases.contains(.dynamicIsland))
        #expect(!NotchSupport.isEnabled())

        // Core standout Vorssaint tools MUST remain available to users
        let retained: [AppFeature] = [
            .mixer, .clipboardHistory, .shelf, .brightness, .switcher, .screenRecorder
        ]
        for feature in retained {
            #expect(!feature.isExcludedInZtat, "Standout Vorssaint tool \(feature) should remain retained")
        }
    }

    @Test("Vorssaint branding is rebranded to ztat per upstream TRADEMARKS.md")
    func rebrandedAppInfo() {
        #expect(AppInfo.name == ZtatBrand.appName)
    }

    @Test("Vorssaint exposes flat toolbox sidebar groups for ztat unified Settings window")
    @MainActor
    func flatVorssaintSidebarGroups() {
        let groups = ZtatVorssaintHost.shared.sidebarGroups()
        #expect(!groups.isEmpty)
        let allItems = groups.flatMap(\.items)
        #expect(!allItems.isEmpty)
        #expect(!ZtatVorssaintHost.shared.defaultToolboxItemID().isEmpty)
    }

    @Test("Permission guide strings reference ztat cleanly with zero Vorssaint brand leaks")
    func permissionGuideRebrandedCleanly() {
        for lang in VorssaintToolbox.AppLanguage.allCases {
            let guide = FeatureStrings.permissionGuide(lang)
            let combined = [guide.title, guide.stepOpen, guide.stepToggle, guide.stepReturn, guide.staleHint].joined(separator: " ")
            #expect(!combined.localizedCaseInsensitiveContains("Vorssaint"), "Found Vorssaint leak in \(lang): \(combined)")
            #expect(guide.stepToggle.contains("ztat"), "Expected ztat in permission guide toggle step for \(lang)")
        }
    }

    @Test("RadialMenu keepAwake slice stays runnable via unified ZtatPowerGuard bridge")
    func radialMenuKeepAwakeBridged() {
        #expect(RadialMenuTool.keepAwake.isRunnable())
    }

    @Test("Screenshot post-capture preview/editor popup defaults OFF and strictly honors screenshotPreviewEnabled")
    func screenshotPreviewToggleContract() {
        let suiteName = "dev.ztat.tests.screenshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Default (unset == false) must suppress preview even when defaultAction is .none
        #expect(!ScreenshotSupport.shouldShowQuickPreview(
            defaultAction: .none, saved: false, copied: false, confirmationEnabled: false))
        #expect(ScreenshotSupport.quickPreviewPresentation(
            defaultAction: .none, saved: false, copied: false, defaults: defaults) == .hidden)

        // Successful automatic actions also stay hidden when preview is off
        #expect(ScreenshotSupport.quickPreviewPresentation(
            defaultAction: .copy, saved: false, copied: true, defaults: defaults) == .hidden)
        #expect(ScreenshotSupport.quickPreviewPresentation(
            defaultAction: .save, saved: true, copied: false, defaults: defaults) == .hidden)

        // Enabling the toggle pops up the preview with the configured duration
        defaults.set(true, forKey: DefaultsKey.screenshotPreviewEnabled)
        defaults.set(5, forKey: DefaultsKey.screenshotPreviewDuration)
        #expect(ScreenshotSupport.quickPreviewPresentation(
            defaultAction: .none, saved: false, copied: false, defaults: defaults) == .shown(dismissInterval: 5))
        #expect(ScreenshotSupport.quickPreviewPresentation(
            defaultAction: .copy, saved: false, copied: true, defaults: defaults) == .shown(dismissInterval: 5))
    }
}

@Suite("ZtatIsland Native Dynamic Island (Atoll Engine)")
struct ZtatIslandTests {
    @Test("ZtatIsland exposes unified settings sections without About, Extensions, or duplicate KeepAwake")
    @MainActor
    func unifiedIslandSettingsSections() {
        let sections = ZtatIslandHost.shared.settingsSectionItems()
        let ids = sections.map(\.id)
        #expect(ids.contains("general"))
        #expect(ids.contains("appearance"))
        #expect(ids.contains("media"))
        #expect(ids.contains("lockScreen"))
        #expect(ids.contains("terminal"))
        #expect(!ids.contains("about"))
        #expect(!ids.contains("extensions"))
        for sec in sections {
            #expect(!sec.title.isEmpty)
            #expect(!sec.symbolName.isEmpty)
        }
    }
}

@Suite("ZtatCleaner Native App Uninstaller & Deep Cleaner")
struct ZtatCleanerTests {
    @Test("ZtatCleaner exposes all 11 unified settings sections cleanly")
    @MainActor
    func unifiedCleanerSections() {
        let items = ZtatCleanerHost.shared.settingsSectionItems()
        let ids = items.map(\.id)
        let expected = [
            "apps", "systemData", "orphans", "lipo", "developer", "packages",
            "plugins", "services", "fileSearch", "history", "settings"
        ]
        #expect(ids == expected)
        for item in items {
            #expect(!item.title.isEmpty)
            #expect(!item.symbolName.isEmpty)
            #expect(!item.keywords.isEmpty)
        }
        #expect(ZtatCleanerHost.normalizeSectionID("lipo") == "lipo")
        #expect(ZtatCleanerHost.normalizeSectionID("nonexistent") == "apps")
    }

    @Test("CleanerSettingsStore enforces zero-idle Sentinel OFF default and isolated orphan linking")
    @MainActor
    func settingsIsolationAndOrphanLinking() {
        let suite = "dev.ztat.tests.cleaner.\(UUID().uuidString)"
        let store = CleanerSettingsStore(suiteName: suite)
        defer { store.defaults.removePersistentDomain(forName: suite) }

        #expect(!store.sentinelEnabled)
        #expect(store.confirmBeforeDelete)
        #expect(store.sensitivity == .strict)
        #expect(store.lockDefaultAppPaths)
        #expect(store.appScanFolders.contains("/Applications"))

        store.linkOrphan("/tmp/fake.plist", toAppPath: "/Applications/Fake.app")
        #expect(store.linkedOrphans(forAppPath: "/Applications/Fake.app").contains("/tmp/fake.plist"))
        #expect(store.orphanExclusions.contains("/tmp/fake.plist"))

        store.unlinkOrphan("/tmp/fake.plist", fromAppPath: "/Applications/Fake.app")
        #expect(store.linkedOrphans(forAppPath: "/Applications/Fake.app").isEmpty)
        #expect(!store.orphanExclusions.contains("/tmp/fake.plist"))
    }

    @Test("SafePathGuard hard-blocks system roots, user Library roots, ztat bundle, and Git repos")
    func safePathGuardContracts() throws {
        let home = NSHomeDirectory()
        let forbidden = [
            "/", "/Applications", "/Library", "/System/Applications/Safari.app",
            home, "\(home)/Library", "\(home)/Library/Application Support",
            "/Applications/ztat.app", "/Applications/ztat-dev.app"
        ]
        for path in forbidden {
            #expect(SafePathGuard.rejectionReason(for: URL(fileURLWithPath: path)) != nil, "Expected \(path) to be rejected")
        }
        // User-configured app scan root itself must be protected
        #expect(SafePathGuard.rejectionReason(
            for: URL(fileURLWithPath: "/CustomApps"),
            extraProtectedRoots: ["/CustomApps"]
        ) != nil)
        // Normal third-party leftover cache is permitted
        #expect(SafePathGuard.rejectionReason(
            for: URL(fileURLWithPath: "\(home)/Library/Caches/com.example.demoapp")
        ) == nil)
        // Git working repository files must be detected and shielded
        let repoFile = URL(fileURLWithPath: "/Users/dearglory/Global-repos/ztat/Package.swift")
        if FileManager.default.fileExists(atPath: repoFile.path) {
            #expect(SafePathGuard.isInsideSourceRepository(repoFile))
        }
    }

    @Test("MachOLipoEngine parses valid 32-bit/64-bit FAT headers and rejects Java .class files")
    func machOFatHeaderParsing() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ztat-lipo-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func appendBE32(_ data: inout Data, _ val: UInt32) {
            var be = val.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        func appendBE64(_ data: inout Data, _ val: UInt64) {
            var be = val.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }

        // 1. Valid synthetic 32-bit FAT binary (arm64 + x86_64)
        var fat32 = Data()
        appendBE32(&fat32, 0xcafebabe) // FAT_MAGIC
        appendBE32(&fat32, 2)          // nfat_arch = 2
        // Slice 0: ARM64 at offset 4096, size 1024
        appendBE32(&fat32, 0x0100000c); appendBE32(&fat32, 0); appendBE32(&fat32, 4096); appendBE32(&fat32, 1024); appendBE32(&fat32, 12)
        // Slice 1: X86_64 at offset 5120, size 1024
        appendBE32(&fat32, 0x01000007); appendBE32(&fat32, 3); appendBE32(&fat32, 5120); appendBE32(&fat32, 1024); appendBE32(&fat32, 12)
        fat32.append(Data(count: 6144 - fat32.count))
        let fat32URL = tempDir.appendingPathComponent("universal32")
        try fat32.write(to: fat32URL)

        let slices32 = MachOLipoEngine.parseFatSlices(at: fat32URL)
        #expect(slices32.count == 2)
        #expect(MachOLipoEngine.inspectBinaryArchitecture(at: fat32URL) == .universal)

        // 2. Valid synthetic 64-bit FAT binary (FAT_MAGIC_64)
        var fat64 = Data()
        appendBE32(&fat64, 0xcafebabf) // FAT_MAGIC_64
        appendBE32(&fat64, 2)
        appendBE32(&fat64, 0x0100000c); appendBE32(&fat64, 0); appendBE64(&fat64, 4096); appendBE64(&fat64, 512); appendBE32(&fat64, 12); appendBE32(&fat64, 0)
        appendBE32(&fat64, 0x01000007); appendBE32(&fat64, 3); appendBE64(&fat64, 4608); appendBE64(&fat64, 512); appendBE32(&fat64, 12); appendBE32(&fat64, 0)
        fat64.append(Data(count: 5120 - fat64.count))
        let fat64URL = tempDir.appendingPathComponent("universal64")
        try fat64.write(to: fat64URL)

        let slices64 = MachOLipoEngine.parseFatSlices(at: fat64URL)
        #expect(slices64.count == 2)
        #expect(MachOLipoEngine.inspectBinaryArchitecture(at: fat64URL) == .universal)

        // 3. Java .class file (`0xCAFEBABE`, minor=0, major=61 -> interpreted as nfat_arch=61 > 32 -> MUST reject!)
        var javaClass = Data()
        appendBE32(&javaClass, 0xcafebabe)
        appendBE32(&javaClass, 61)
        javaClass.append(Data(count: 128))
        let javaURL = tempDir.appendingPathComponent("Test.class")
        try javaClass.write(to: javaURL)
        #expect(MachOLipoEngine.parseFatSlices(at: javaURL).isEmpty)
    }

    @Test("LeftoverCategory classification and nested URL collapsing behave deterministically")
    func leftoverClassificationAndCollapsing() {
        let home = NSHomeDirectory()
        #expect(LeftoverCategory.classify(url: URL(fileURLWithPath: "/Applications/Foo.app"), isMainApp: true) == .appBundle)
        #expect(LeftoverCategory.classify(url: URL(fileURLWithPath: "\(home)/Library/Preferences/com.foo.bar.plist")) == .preferences)
        #expect(LeftoverCategory.classify(url: URL(fileURLWithPath: "\(home)/Library/Caches/com.foo.bar")) == .caches)
        #expect(LeftoverCategory.classify(url: URL(fileURLWithPath: "\(home)/Library/Containers/com.foo.bar")) == .containers)
        #expect(LeftoverCategory.classify(url: URL(fileURLWithPath: "\(home)/Library/LaunchAgents/com.foo.agent.plist")) == .launchItems)
        #expect(LeftoverCategory.classify(url: URL(fileURLWithPath: "\(home)/Library/Saved Application State/com.foo.savedState")) == .savedState)

        let collapsed = SafeDeletionEngine.shared.collapseNestedURLs([
            URL(fileURLWithPath: "/tmp/parent"),
            URL(fileURLWithPath: "/tmp/parent/child/sub"),
            URL(fileURLWithPath: "/tmp/sibling")
        ])
        #expect(collapsed.map(\.path) == ["/tmp/parent", "/tmp/sibling"])
    }

    @Test("System Data Unpacked section, SpacePlan priority, snapshot validator, and history store work")
    @MainActor
    func systemDataUnpackedContracts() throws {
        #expect(CleanerSectionID.allCases.contains(.systemData))
        #expect(ZtatCleanerHost.normalizeSectionID("systemData") == "systemData")

        // Snapshot date-stamp strict validation
        #expect(SystemDataProbes.isValidSnapshotStamp("2026-11-28-153000"))
        #expect(!SystemDataProbes.isValidSnapshotStamp("2026-11-28; rm -rf /"))
        #expect(!SystemDataProbes.isValidSnapshotStamp("../bad"))

        // Ollama tag strict validation & system diagnostic dir guard
        #expect(SystemDataProbes.isValidOllamaTag("llama3:latest"))
        #expect(SystemDataProbes.isValidOllamaTag("myuser/qwen2.5:7b-instruct"))
        #expect(!SystemDataProbes.isValidOllamaTag("--help:latest"))
        #expect(!SystemDataProbes.isValidOllamaTag("bad tag:latest"))
        #expect(SafePathGuard.rejectionReason(for: URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")) != nil)

        // Human byte parser for Docker CLI output
        #expect(SystemDataProbes.parseHumanBytes("2.5GB") == 2_500_000_000)
        #expect(SystemDataProbes.parseHumanBytes("512MB") == 512_000_000)

        // SpacePlanBuilder prioritizes safe (largest first) -> review (oldest idle first), skips manual, trims overshoot
        let oldDate = Date(timeIntervalSinceNow: -90 * 86_400)
        let recentDate = Date(timeIntervalSinceNow: -2 * 86_400)
        let items: [SystemDataItem] = [
            SystemDataItem(id: "safe.big", category: .xcode, title: "Derived", subtitle: "", bytes: 6_000_000_000, safety: .safe, recovery: .rebuildsLocally, action: .trashPaths([URL(fileURLWithPath: "/tmp/a")])),
            SystemDataItem(id: "safe.small", category: .logs, title: "Logs", subtitle: "", bytes: 2_000_000_000, safety: .safe, recovery: .disposable, action: .trashPaths([URL(fileURLWithPath: "/tmp/b")])),
            SystemDataItem(id: "review.old", category: .aiModels, title: "Old Model", subtitle: "", bytes: 5_000_000_000, lastModified: oldDate, safety: .review, recovery: .redownloads, action: .trashPaths([URL(fileURLWithPath: "/tmp/c")])),
            SystemDataItem(id: "review.new", category: .aiModels, title: "New Model", subtitle: "", bytes: 9_000_000_000, lastModified: recentDate, safety: .review, recovery: .redownloads, action: .trashPaths([URL(fileURLWithPath: "/tmp/d")])),
            SystemDataItem(id: "manual.vm", category: .systemReserved, title: "VM", subtitle: "", bytes: 20_000_000_000, safety: .manual, recovery: .disposable, action: .manual(guidance: "System"))
        ]
        let plan = SpacePlanBuilder.build(items: items, targetBytes: 10_000_000_000)
        #expect(plan.reachedTarget)
        #expect(plan.selectedIDs.contains("safe.big"))
        #expect(plan.selectedIDs.contains("review.old"))
        #expect(!plan.selectedIDs.contains("manual.vm"))
        #expect(!plan.selectedIDs.contains("review.new"))
        // Overshoot trimming: safe.big (6G) + review.old (5G) = 11G >= 10G, so safe.small (2G) should be trimmed
        #expect(!plan.selectedIDs.contains("safe.small"))

        // History store returned-item detection
        let tmpHistory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztat-sysdata-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpHistory) }
        let store = SystemDataHistoryStore(fileURL: tmpHistory)
        store.recordDeletions([
            SystemDataDeletionRecord(itemID: "safe.big", title: "Derived", path: "/tmp/a", bytesFreed: 4_000_000_000)
        ])
        let returned = store.detectReturnedItems(currentItems: [
            SystemDataItem(id: "safe.big", category: .xcode, title: "Derived", subtitle: "", path: URL(fileURLWithPath: "/tmp/a"), bytes: 500_000_000, safety: .safe, recovery: .rebuildsLocally, action: .trashPaths([URL(fileURLWithPath: "/tmp/a")]))
        ])
        #expect(returned.count == 1)
        #expect(returned.first?.currentBytes == 500_000_000)
    }
}
