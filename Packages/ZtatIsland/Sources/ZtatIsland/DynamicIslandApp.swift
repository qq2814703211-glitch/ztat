/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

// ZTAT-PATCH: Embed native Atoll Dynamic Island engine into ztat without @main App,
// MenuBarExtra, Sparkle, onboarding, top-menu injection, or eager disabled monitors.

import AppKit
import AVFoundation
import Combine
import Defaults
import Foundation
import KeyboardShortcuts
import SwiftUI
import ZtatCore

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

// ZTAT-PATCH: Keep existing `AppDelegate.shared` references in DynamicIslandViewModel,
// DynamicIslandHeader, and ContentView working cleanly against ZtatIslandController.
typealias AppDelegate = ZtatIslandController

// MARK: - Public Embedded Host Facade

/// Single public lifecycle and settings facade exposed by `ZtatIsland` to `ZtatApp`.
@MainActor
public final class ZtatIslandHost: ObservableObject {
    public static let shared = ZtatIslandHost()

    @Published public private(set) var isEnabled: Bool

    private var controller: ZtatIslandController?

    private static let atollMigrationMarkerKey = "ztat.didMigratePreferencesFromAtoll.v1"

    private init() {
        self.isEnabled = Defaults[.enableDynamicIsland]
    }

    public func start() {
        isEnabled = Defaults[.enableDynamicIsland]
        guard isEnabled else { return }

        if controller == nil {
            controller = ZtatIslandController()
        }
        controller?.start()
    }

    public func stop() {
        controller?.stop()
        controller = nil
    }

    public func setEnabled(_ enabled: Bool) {
        Defaults[.enableDynamicIsland] = enabled
        isEnabled = enabled

        if enabled {
            start()
        } else {
            stop()
        }

        NotificationCenter.default.post(name: .ztatIslandDidChange, object: enabled)
    }

    public func toggleNotchOpen() {
        guard isEnabled else { return }
        if controller == nil {
            start()
        }
        controller?.toggleNotchOpen(autoCloseAfter: nil)
    }

    public func closeNotch() {
        controller?.closeNotch()
    }

    public func settingsSectionItems() -> [ZtatIslandSectionItem] {
        ZtatIslandSettingsRouter.visibleSectionItems()
    }

    public func makeSettingsDetailView(sectionID: String) -> AnyView {
        ZtatIslandSettingsRouter.makeDetailView(sectionID: sectionID)
    }

    /// One-time migration from standalone Atoll preferences (`com.Ebullioscopic.Atoll`)
    /// into ztat's isolated `islandDefaults` suite, stripping Sparkle keys, forcing
    /// embedded-safe flags, and rewriting stale `/Applications/Atoll.app` Lottie URLs.
    public static func migratePreferencesFromAtollIfNeeded() {
        guard !islandDefaults.bool(forKey: atollMigrationMarkerKey) else { return }

        defer {
            // Always force embedded-safe defaults so ztat never spawns a duplicate
            // Atoll menu bar icon or standalone Atoll onboarding/what's-new flow.
            islandDefaults.set(false, forKey: "menubarIcon")
            islandDefaults.set(false, forKey: "firstLaunch")
            islandDefaults.set(false, forKey: "showWhatsNew")
            Defaults[.menubarIcon] = false
            islandDefaults.set(true, forKey: atollMigrationMarkerKey)
            islandDefaults.synchronize()
        }

        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.Ebullioscopic.Atoll.plist")

        let sourceDict: [String: Any]? =
            (NSDictionary(contentsOf: plistURL) as? [String: Any])
            ?? UserDefaults(suiteName: "com.Ebullioscopic.Atoll")?
                .persistentDomain(forName: "com.Ebullioscopic.Atoll")

        if let sourceDict {
            for (key, value) in sourceDict {
                if key.hasPrefix("SU")
                    || key.hasPrefix("Sparkle")
                    || key.hasPrefix("NSStatusItem")
                    || key == "menubarIcon"
                    || key == "firstLaunch"
                    || key == "showWhatsNew"
                {
                    continue
                }
                if islandDefaults.object(forKey: key) == nil {
                    islandDefaults.set(value, forKey: key)
                }
            }
        }

        func rewriteIdleAnimationURL(_ animation: CustomIdleAnimation) -> CustomIdleAnimation {
            var updated = animation
            if case .lottieFile(let url) = animation.source {
                let pointsIntoStandaloneAtoll = url.path.contains("/Atoll.app/")
                let missingOnDisk = !FileManager.default.fileExists(atPath: url.path)
                if pointsIntoStandaloneAtoll || missingOnDisk {
                    if let bundled = ZtatIslandResources.lottieURL(named: url.lastPathComponent)
                        ?? ZtatIslandResources.lottieURL(named: animation.name)
                    {
                        updated.source = .lottieFile(bundled)
                    }
                }
            }
            return updated
        }

        let existingAnimations = Defaults[.customIdleAnimations]
        let rewrittenAnimations = existingAnimations.map(rewriteIdleAnimationURL)
        if rewrittenAnimations != existingAnimations {
            Defaults[.customIdleAnimations] = rewrittenAnimations
        }

        if let selected = Defaults[.selectedIdleAnimation] {
            let rewrittenSelected = rewriteIdleAnimationURL(selected)
            if rewrittenSelected != selected {
                Defaults[.selectedIdleAnimation] = rewrittenSelected
            }
        }
    }
}

// MARK: - Embedded Dynamic Island Controller

@MainActor
final class ZtatIslandController: NSObject {
    // ZTAT-PATCH: Stored static reference set while running — NOT `NSApplication.shared.delegate as? AppDelegate`.
    static var shared: ZtatIslandController?

    var windows: [NSScreen: NSWindow] = [:]
    var viewModels: [NSScreen: DynamicIslandViewModel] = [:]
    var window: NSWindow?
    let vm: DynamicIslandViewModel = .init()
    let coordinator = DynamicIslandViewCoordinator.shared
    var closeNotchWorkItem: DispatchWorkItem?

    private var previousScreens: [NSScreen]?
    private var cancellables = Set<AnyCancellable>()
    private var observerTokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var audioTapObserverTokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var windowsHiddenForLock = false
    private var optionalShortcutHandlersRegistered = false
    private var windowSizeUpdateWorkItem: DispatchWorkItem?

    private var isRunning = false
    private var didStartNetworkConnectivity = false
    private var didStartPrivacyIndicator = false
    private var didStartScreenRecording = false

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        ZtatIslandController.shared = self

        // Ensure embedded defaults never trigger standalone Atoll onboarding/menu bar UI.
        Defaults[.menubarIcon] = false
        if coordinator.firstLaunch {
            coordinator.firstLaunch = false
        }

        LockScreenLiveActivityWindowManager.shared.configure(viewModel: vm)
        LockScreenManager.shared.configure(viewModel: vm)

        // ZTAT-PATCH: Never start ExtensionXPCServiceHost or ExtensionRPCServer automatically.

        // Migrate legacy preferences
        Defaults.Keys.migrateProgressBarStyle()
        Defaults.Keys.migrateMusicAuxControls()
        Defaults.Keys.migrateMusicControlSlots()
        Defaults.Keys.migrateCapsLockTintMode()
        Defaults.Keys.migrateThirdPartyDDCIntegration()
        Defaults.Keys.migrateClipboardShortcutToV()

        Defaults.publisher(.enableThirdPartyDDCIntegration, options: [])
            .receive(on: DispatchQueue.main)
            .sink { _ in
                Defaults.Keys.syncLegacyThirdPartyDDCKeys()
            }
            .store(in: &cancellables)

        Defaults.publisher(.thirdPartyDDCProvider, options: [])
            .receive(on: DispatchQueue.main)
            .sink { _ in
                Defaults.Keys.syncLegacyThirdPartyDDCKeys()
            }
            .store(in: &cancellables)

        // Initialize idle animations (load bundled Lottie assets)
        IdleAnimationManager.shared.initializeDefaultAnimations()

        // Ensure media-controls state coordinator is active while island runs
        _ = MediaControlsStateCoordinator.shared
        if MusicManager.hasInitialized {
            MusicManager.shared.restartActiveControllerIfNeeded()
        }

        // Setup SystemHUD, BetterDisplay, and Lunar integrations
        SystemHUDManager.shared.setup(coordinator: coordinator)
        BetterDisplayManager.shared.configure(coordinator: coordinator)
        LunarManager.shared.configure(coordinator: coordinator)

        // Honour "Save History Across Restarts" before anything reads stored history
        ClipboardManager.purgeStoredHistoryIfPersistenceDisabled()

        // ZTAT-PATCH: Lazily start & dynamically gate monitors so disabled subsystems
        // never spawn `/usr/bin/log stream`, `CLLocationManager`, or `IOBluetooth` polling.
        setupGatedSubsystems()

        // Setup Real-time Audio Waveform capture if enabled
        if Defaults[.enableRealTimeWaveform] {
            Task {
                await AudioTap.shared.startCapture()
            }
            setupAudioTapMusicObservers()
        }

        Defaults.publisher(.enableRealTimeWaveform, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self, self.isRunning else { return }
                if change.newValue {
                    Task {
                        await AudioTap.shared.startCapture()
                    }
                    self.setupAudioTapMusicObservers()
                } else {
                    AudioTap.shared.stopCapture()
                    self.tearDownAudioTapMusicObservers()
                }
            }
            .store(in: &cancellables)

        setupSizingAndFeatureObservers()
        setupSystemAndScreenObservers()
        setupKeyboardShortcuts()

        // Create and position Dynamic Island window(s)
        if !Defaults[.showOnAllDisplays] {
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let window = createDynamicIslandWindow(for: screen, with: vm)
                self.window = window
                adjustWindowPosition(changeAlpha: true)
            }
        } else {
            adjustWindowPosition(changeAlpha: true)
        }

        previousScreens = NSScreen.screens
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        // 1. CRITICAL: Synchronously resume macOS OSDUIHelper so native OSD is never left SIGSTOP-frozen.
        SystemOSDManager.resumeOSDUIHelperForTermination()

        // 2. Restore Lunar's native OSD if integration was active.
        LunarManager.shared.appWillTerminate()

        // 3. Restore fullscreen lock-screen artwork / resume wallpaper agent if active.
        if FullScreenArtworkWindowManager.shared.isShowing {
            FullScreenArtworkWindowManager.shared.hide()
        }

        // 4. Stop CoreAudio Process Tap capture and observers.
        tearDownAudioTapMusicObservers()
        AudioTap.shared.stopCapture()

        // 5. Synchronously terminate all persistent child processes (perl / log stream).
        if MusicManager.hasInitialized {
            MusicManager.shared.stopActiveController()
        }
        if SystemTimerBridge.hasInitialized {
            SystemTimerBridge.shared.stopMonitoringIfStarted()
        }
        if DoNotDisturbManager.hasInitialized {
            DoNotDisturbManager.shared.stopMonitoring()
        }
        if BluetoothAudioManager.hasInitialized {
            BluetoothAudioManager.shared.stopMonitoringIfStarted()
        }

        // Stop remaining active monitors without waking disabled singletons.
        if didStartNetworkConnectivity {
            NetworkConnectivityManager.shared.stopMonitoring()
            didStartNetworkConnectivity = false
        }
        if didStartPrivacyIndicator {
            PrivacyIndicatorManager.shared.stopMonitoring()
            didStartPrivacyIndicator = false
        }
        if didStartScreenRecording {
            ScreenRecordingManager.shared.stopMonitoring()
            didStartScreenRecording = false
        }
        if CalendarManager.hasInitialized {
            CalendarManager.shared.stopLockScreenRefreshLoop()
        }
        if StatsManager.hasInitialized {
            StatsManager.shared.stopMonitoring()
        }
        if LockScreenWeatherManager.hasInitialized {
            LockScreenWeatherManager.shared.hideWeatherWidget()
        }

        // Disable island keyboard shortcuts while stopped.
        disableAllIslandShortcuts()

        // 6. Cancel pending work items, Combine subscriptions, notification observers, and windows.
        windowSizeUpdateWorkItem?.cancel()
        windowSizeUpdateWorkItem = nil
        closeNotchWorkItem?.cancel()
        closeNotchWorkItem = nil

        cancellables.removeAll()

        for (center, token) in observerTokens {
            center.removeObserver(token)
        }
        observerTokens.removeAll()
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)

        cleanupAllWindows()
        NotchSpaceManager.shared.notchSpace.windows.removeAll()
        windowsHiddenForLock = false

        if ZtatIslandController.shared === self {
            ZtatIslandController.shared = nil
        }
    }

    // MARK: - Gated Subsystems

    private var shouldEnableCalendar: Bool {
        Defaults[.showCalendar]
            || Defaults[.enableLockScreenWeatherWidget]
            || Defaults[.enableLockScreenReminderWidget]
    }

    private var shouldEnableBluetooth: Bool {
        Defaults[.showBluetoothDeviceConnections]
            || Defaults[.showAirPodsListeningModeChanges]
    }

    private func setupGatedSubsystems() {
        // CalendarManager: only start when calendar or lock-screen weather/reminder widgets are enabled.
        if shouldEnableCalendar {
            CalendarManager.shared.ensureStartedIfNeeded()
        }
        Publishers.MergeMany(
            Defaults.publisher(.showCalendar, options: []).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableLockScreenWeatherWidget, options: []).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableLockScreenReminderWidget, options: []).map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self, self.isRunning else { return }
            if self.shouldEnableCalendar {
                CalendarManager.shared.ensureStartedIfNeeded()
            } else if CalendarManager.hasInitialized {
                CalendarManager.shared.stopLockScreenRefreshLoop()
            }
        }
        .store(in: &cancellables)

        // SystemTimerBridge: only start when Timer feature is enabled.
        if Defaults[.enableTimerFeature] && !AppRuntimeEnvironment.isUITesting {
            SystemTimerBridge.shared.startMonitoring()
            if Defaults[.enableLockScreenTimerWidget] {
                LockScreenTimerWidgetManager.shared.handleLockStateChange(
                    isLocked: LockScreenManager.shared.currentLockStatus
                )
            }
        }
        Defaults.publisher(.enableTimerFeature, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self, self.isRunning else { return }
                if change.newValue && !AppRuntimeEnvironment.isUITesting {
                    SystemTimerBridge.shared.startMonitoring()
                    if Defaults[.enableLockScreenTimerWidget] {
                        LockScreenTimerWidgetManager.shared.handleLockStateChange(
                            isLocked: LockScreenManager.shared.currentLockStatus
                        )
                    }
                } else if SystemTimerBridge.hasInitialized {
                    SystemTimerBridge.shared.stopMonitoringIfStarted()
                }
                self.updateFeatureShortcutAvailability()
            }
            .store(in: &cancellables)

        // DoNotDisturbManager: only start when Focus/DND detection is enabled.
        if Defaults[.enableDoNotDisturbDetection] && !AppRuntimeEnvironment.isUITesting {
            DoNotDisturbManager.shared.startMonitoring()
        }
        Defaults.publisher(.enableDoNotDisturbDetection, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self, self.isRunning else { return }
                if change.newValue && !AppRuntimeEnvironment.isUITesting {
                    DoNotDisturbManager.shared.startMonitoring()
                } else if DoNotDisturbManager.hasInitialized {
                    DoNotDisturbManager.shared.stopMonitoring()
                }
            }
            .store(in: &cancellables)

        // BluetoothAudioManager: only start when Bluetooth connections or AirPods listening mode HUD is enabled.
        if shouldEnableBluetooth && !AppRuntimeEnvironment.isUITesting {
            BluetoothAudioManager.shared.startMonitoring()
        }
        Publishers.MergeMany(
            Defaults.publisher(.showBluetoothDeviceConnections, options: []).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.showAirPodsListeningModeChanges, options: []).map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self, self.isRunning else { return }
            if self.shouldEnableBluetooth && !AppRuntimeEnvironment.isUITesting {
                BluetoothAudioManager.shared.startMonitoring()
            } else if BluetoothAudioManager.hasInitialized {
                BluetoothAudioManager.shared.stopMonitoringIfStarted()
            }
        }
        .store(in: &cancellables)

        // ScreenRecordingManager
        if Defaults[.enableScreenRecordingDetection] && !AppRuntimeEnvironment.isUITesting {
            ScreenRecordingManager.shared.startMonitoring()
            didStartScreenRecording = true
        }
        Defaults.publisher(.enableScreenRecordingDetection, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self, self.isRunning else { return }
                if change.newValue && !AppRuntimeEnvironment.isUITesting {
                    ScreenRecordingManager.shared.startMonitoring()
                    self.didStartScreenRecording = true
                } else {
                    ScreenRecordingManager.shared.stopMonitoring()
                    self.didStartScreenRecording = false
                }
            }
            .store(in: &cancellables)

        // PrivacyIndicatorManager & NetworkConnectivityManager
        if !AppRuntimeEnvironment.isUITesting {
            PrivacyIndicatorManager.shared.startMonitoring()
            didStartPrivacyIndicator = true

            NetworkConnectivityManager.shared.startMonitoring()
            didStartNetworkConnectivity = true
        }

        // DownloadManager: only touch when download listener is enabled.
        if Defaults[.enableDownloadListener] && !AppRuntimeEnvironment.isUITesting {
            _ = DownloadManager.shared
        }

        // LockScreenWeatherManager: never touch CLLocationManager or network unless enabled.
        if Defaults[.enableLockScreenWeatherWidget] && !AppRuntimeEnvironment.isUITesting {
            LockScreenWeatherManager.shared.prepareLocationAccess()
            Task { @MainActor in
                _ = await LockScreenWeatherManager.shared.refresh(force: true)
            }
        }
        Defaults.publisher(.enableLockScreenWeatherWidget, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self, self.isRunning else { return }
                if change.newValue && !AppRuntimeEnvironment.isUITesting {
                    LockScreenWeatherManager.shared.prepareLocationAccess()
                    Task { @MainActor in
                        _ = await LockScreenWeatherManager.shared.refresh(force: true)
                    }
                } else if LockScreenWeatherManager.hasInitialized {
                    LockScreenWeatherManager.shared.hideWeatherWidget()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Notch Open / Close Controls

    func toggleNotchOpen(autoCloseAfter: TimeInterval? = nil) {
        let viewModel = activeViewModelUnderCursor()
        cancelPendingNotchAutoClose()

        switch viewModel.notchState {
        case .closed:
            viewModel.open()
            if let autoCloseAfter {
                let workItem = DispatchWorkItem { [weak viewModel] in
                    Task { @MainActor in
                        viewModel?.close()
                    }
                }
                closeNotchWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + autoCloseAfter, execute: workItem)
            }
        case .open:
            viewModel.close()
        }
    }

    func closeNotch() {
        cancelPendingNotchAutoClose()
        if Defaults[.showOnAllDisplays] {
            for viewModel in viewModels.values where viewModel.notchState == .open {
                viewModel.close()
            }
        }
        if vm.notchState == .open {
            vm.close()
        }
    }

    private func activeViewModelUnderCursor() -> DynamicIslandViewModel {
        var viewModel = vm
        if Defaults[.showOnAllDisplays] {
            let mouseLocation = NSEvent.mouseLocation
            for screen in NSScreen.screens where screen.frame.contains(mouseLocation) {
                if let screenViewModel = viewModels[screen] {
                    viewModel = screenViewModel
                    break
                }
            }
        }
        return viewModel
    }

    // Cancel the auto-close armed by `toggleNotchOpen`. Switching to the clipboard tab
    // from the header only changes `coordinator.currentView`, so without this the notch
    // can close mid-copy/drag a few seconds after it was opened.
    func cancelPendingNotchAutoClose() {
        closeNotchWorkItem?.cancel()
        closeNotchWorkItem = nil
    }

    // MARK: - Observers & Subscriptions

    private func setupSizingAndFeatureObservers() {
        // Observe tab changes - use immediate resize to keep the notch pinned.
        // Deferred to next run loop tick because @Published fires on willSet,
        // so coordinator.currentView still holds the OLD value at emission time.
        coordinator.$currentView.sink { [weak self] _ in
            DispatchQueue.main.async {
                Task { @MainActor [weak self] in
                    self?.updateWindowSizeForTabSwitch()
                }
            }
        }.store(in: &cancellables)

        NetworkConnectivityManager.shared.$hudState
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    Task { @MainActor [weak self] in
                        self?.updateWindowSizeIfNeeded()
                    }
                }
            }
            .store(in: &cancellables)

        MusicManager.shared.$isAdvertisement
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    Task { @MainActor [weak self] in
                        self?.updateWindowSizeIfNeeded()
                    }
                }
            }
            .store(in: &cancellables)

        coordinator.$notesLayoutState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateWindowSizeIfNeeded()
                }
            }
            .store(in: &cancellables)

        // Observe stats settings changes - use debounced updates
        Defaults.publisher(.enableStatsFeature, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.debouncedUpdateWindowSize() }
        }.store(in: &cancellables)

        Defaults.publisher(.showCpuGraph, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.debouncedUpdateWindowSize() }
        }.store(in: &cancellables)

        Defaults.publisher(.showMemoryGraph, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.debouncedUpdateWindowSize() }
        }.store(in: &cancellables)

        Defaults.publisher(.showGpuGraph, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.debouncedUpdateWindowSize() }
        }.store(in: &cancellables)

        Defaults.publisher(.showNetworkGraph, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.debouncedUpdateWindowSize() }
        }.store(in: &cancellables)

        Defaults.publisher(.showDiskGraph, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.debouncedUpdateWindowSize() }
        }.store(in: &cancellables)

        Defaults.publisher(.openNotchWidth, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.debouncedUpdateWindowSize() }
        }.store(in: &cancellables)

        // Observe terminal settings changes
        Defaults.publisher(.enableTerminalFeature, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.debouncedUpdateWindowSize()
                self?.updateFeatureShortcutAvailability()
            }
        }.store(in: &cancellables)

        Defaults.publisher(.terminalMaxHeightFraction, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.debouncedUpdateWindowSize() }
        }.store(in: &cancellables)

        ReminderLiveActivityManager.shared.$activeWindowReminders
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.debouncedUpdateWindowSize() }
            }
            .store(in: &cancellables)

        TimerManager.shared.$activeSource
            .combineLatest(TimerManager.shared.$isTimerActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.debouncedUpdateWindowSize() }
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableShortcuts, options: []).sink { [weak self] change in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                KeyboardShortcuts.isEnabled = change.newValue
                self.updateFeatureShortcutAvailability()
            }
        }.store(in: &cancellables)

        Defaults.publisher(.enableClipboardManager, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFeatureShortcutAvailability()
            }
        }.store(in: &cancellables)

        Defaults.publisher(.enableColorPickerFeature, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFeatureShortcutAvailability()
            }
        }.store(in: &cancellables)

        Defaults.publisher(.enableScreenAssistant, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFeatureShortcutAvailability()
            }
        }.store(in: &cancellables)

        Defaults.publisher(.enableCaffeinate, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFeatureShortcutAvailability()
            }
        }.store(in: &cancellables)

        Defaults.publisher(.hideNotchOption, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncNotchSpaceMembership()
            }
        }.store(in: &cancellables)

        // Observe minimalistic UI setting changes - trigger window resize immediately
        Defaults.publisher(.enableMinimalisticUI, options: []).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateWindowSizeIfNeeded()
            }
        }.store(in: &cancellables)
    }

    private func addTrackedObserver(
        center: NotificationCenter,
        name: Notification.Name,
        handler: @escaping @MainActor (Notification) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
            Task { @MainActor in
                handler(notification)
            }
        }
        observerTokens.append((center, token))
    }

    private func setupSystemAndScreenObservers() {
        addTrackedObserver(
            center: NotificationCenter.default,
            name: NSApplication.didChangeScreenParametersNotification
        ) { [weak self] _ in
            self?.screenConfigurationDidChange()
        }

        addTrackedObserver(
            center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.activeSpaceDidChangeNotification
        ) { [weak self] _ in
            self?.reassertDynamicIslandWindowSpacePresence()
            self?.adjustWindowPosition()
        }

        addTrackedObserver(
            center: NotificationCenter.default,
            name: Notification.Name.selectedScreenChanged
        ) { [weak self] _ in
            self?.adjustWindowPosition(changeAlpha: true)
        }

        addTrackedObserver(
            center: NotificationCenter.default,
            name: Notification.Name.notchHeightChanged
        ) { [weak self] _ in
            self?.adjustWindowPosition()
        }

        addTrackedObserver(
            center: NotificationCenter.default,
            name: Notification.Name.automaticallySwitchDisplayChanged
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            window.alphaValue = self.coordinator.selectedScreen == self.coordinator.preferredScreen ? 1 : 0
        }

        addTrackedObserver(
            center: NotificationCenter.default,
            name: Notification.Name.showOnAllDisplaysChanged
        ) { [weak self] _ in
            guard let self else { return }
            self.cleanupWindows(shouldInvert: true)

            if !Defaults[.showOnAllDisplays] {
                guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
                let window = self.createDynamicIslandWindow(for: screen, with: self.vm)
                self.window = window
                self.adjustWindowPosition(changeAlpha: true)
            } else {
                self.adjustWindowPosition()
            }
        }

        addTrackedObserver(
            center: DistributedNotificationCenter.default(),
            name: NSNotification.Name(rawValue: "com.apple.screenIsLocked")
        ) { [weak self] _ in
            self?.onScreenLocked()
        }

        addTrackedObserver(
            center: DistributedNotificationCenter.default(),
            name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked")
        ) { [weak self] _ in
            self?.onScreenUnlocked()
        }
    }

    // MARK: - AudioTap Observers

    private func setupAudioTapMusicObservers() {
        tearDownAudioTapMusicObservers()

        let targetBundleIDs = [
            "com.apple.Music",
            "com.spotify.client",
            "com.amazon.music",
            "sh.cider.genten.mac",
            "com.apple.Safari",
            "com.tidal.desktop",
            "tv.plex.plexamp",
            "com.roon.Roon",
            "com.audirvana.Audirvana-Studio",
            "com.vox.vox",
            "com.coppertino.Vox",
        ]

        let launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  targetBundleIDs.contains(bundleID) else { return }

            if Defaults[.enableRealTimeWaveform] {
                print("🎵 [AudioTap] Music app launched: \(bundleID), restarting capture...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    AudioTap.shared.restartCapture()
                }
            }
        }

        let terminateToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  targetBundleIDs.contains(bundleID) else { return }

            if Defaults[.enableRealTimeWaveform] {
                print("🎵 [AudioTap] Music app terminated: \(bundleID), restarting capture...")
                AudioTap.shared.restartCapture()
            }
        }

        let routeToken = NotificationCenter.default.addObserver(
            forName: .systemAudioRouteDidChange,
            object: nil,
            queue: .main
        ) { _ in
            if Defaults[.enableRealTimeWaveform] {
                print("🔀 [AudioTap] Audio route changed, restarting capture...")
                AudioTap.shared.restartCapture()
            }
        }

        audioTapObserverTokens = [
            (NSWorkspace.shared.notificationCenter, launchToken),
            (NSWorkspace.shared.notificationCenter, terminateToken),
            (NotificationCenter.default, routeToken),
        ]
    }

    private func tearDownAudioTapMusicObservers() {
        for (center, token) in audioTapObserverTokens {
            center.removeObserver(token)
        }
        audioTapObserverTokens.removeAll()
    }

    // MARK: - Keyboard Shortcuts

    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self, self.isRunning else { return }
            guard Defaults[.enableShortcuts] else { return }

            self.coordinator.toggleSneakPeek(
                status: !self.coordinator.sneakPeek.show,
                type: .music,
                duration: 3.0
            )
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            guard let self, self.isRunning else { return }
            guard Defaults[.enableShortcuts] else { return }
            self.toggleNotchOpen(autoCloseAfter: 3.0)
        }

        KeyboardShortcuts.isEnabled = Defaults[.enableShortcuts]
        updateShortcut(.toggleSneakPeek, isEnabled: Defaults[.enableShortcuts])
        updateShortcut(.toggleNotchOpen, isEnabled: Defaults[.enableShortcuts])
        registerOptionalShortcutHandlers()
        updateFeatureShortcutAvailability()
    }

    private func registerOptionalShortcutHandlers() {
        guard !optionalShortcutHandlersRegistered else { return }
        optionalShortcutHandlersRegistered = true

        KeyboardShortcuts.onKeyDown(for: .startDemoTimer) { [weak self] in
            guard let self, self.isRunning else { return }
            guard Defaults[.enableShortcuts], Defaults[.enableTimerFeature] else { return }
            TimerManager.shared.startDemoTimer(duration: 300)
        }

        KeyboardShortcuts.onKeyDown(for: .clipboardHistoryPanel) { [weak self] in
            guard let self, self.isRunning else { return }
            guard Defaults[.enableShortcuts], Defaults[.enableClipboardManager] else { return }

            if !ClipboardManager.shared.isMonitoring {
                ClipboardManager.shared.startMonitoring()
            }

            switch Defaults[.clipboardDisplayMode] {
            case .panel:
                ClipboardPanelManager.shared.toggleClipboardPanel()
            case .popover:
                if vm.notchState == .closed {
                    vm.open()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(name: NSNotification.Name("ToggleClipboardPopover"), object: nil)
                    }
                } else {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleClipboardPopover"), object: nil)
                }
            case .separateTab:
                if vm.notchState == .closed {
                    vm.open()
                    coordinator.currentView = .notes
                } else {
                    if coordinator.currentView == .notes {
                        vm.close()
                    } else {
                        coordinator.currentView = .notes
                    }
                }
            case .notchTab:
                let activeVM = activeViewModelUnderCursor()
                cancelPendingNotchAutoClose()
                if activeVM.notchState == .closed {
                    activeVM.open()
                    coordinator.currentView = .clipboard
                } else {
                    if coordinator.currentView == .clipboard {
                        activeVM.close()
                    } else {
                        coordinator.currentView = .clipboard
                    }
                }
            }
        }

        KeyboardShortcuts.onKeyDown(for: .colorPickerPanel) { [weak self] in
            guard let self, self.isRunning else { return }
            guard Defaults[.enableShortcuts], Defaults[.enableColorPickerFeature] else { return }
            ColorPickerPanelManager.shared.toggleColorPickerPanel()
        }

        KeyboardShortcuts.onKeyDown(for: .toggleCaffeinate) { [weak self] in
            guard let self, self.isRunning else { return }
            guard Defaults[.enableShortcuts], Defaults[.enableCaffeinate] else { return }
            CaffeinateManager.shared.toggle()
        }

        KeyboardShortcuts.onKeyDown(for: .toggleTerminalTab) { [weak self] in
            guard let self, self.isRunning else { return }
            guard Defaults[.enableShortcuts], Defaults[.enableTerminalFeature] else { return }

            if vm.notchState == .closed {
                closeNotchWorkItem?.cancel()
                closeNotchWorkItem = nil
                vm.open()
                coordinator.currentView = .terminal
                TerminalManager.shared.refreshTerminalAppearanceIfNeeded()
                TerminalManager.shared.focusTerminalIfPossible()
                TerminalManager.shared.refreshTerminalAppearanceIfNeeded()
            } else {
                if coordinator.currentView == .terminal {
                    coordinator.suppressHoverOpen()
                    TerminalManager.shared.resignTerminalFirstResponderIfNeeded()
                    vm.close()
                } else {
                    closeNotchWorkItem?.cancel()
                    closeNotchWorkItem = nil
                    coordinator.currentView = .terminal
                    TerminalManager.shared.refreshTerminalAppearanceIfNeeded()
                    TerminalManager.shared.focusTerminalIfPossible()
                    TerminalManager.shared.refreshTerminalAppearanceIfNeeded()
                }
            }
        }

        KeyboardShortcuts.onKeyDown(for: .screenAssistantPanel) { [weak self] in
            guard let self, self.isRunning else { return }
            guard Defaults[.enableShortcuts], Defaults[.enableScreenAssistant] else { return }

            switch Defaults[.screenAssistantDisplayMode] {
            case .panel:
                ScreenAssistantPanelManager.shared.toggleScreenAssistantPanel()
            case .popover:
                if vm.notchState == .closed {
                    vm.open()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(name: NSNotification.Name("ToggleScreenAssistantPopover"), object: nil)
                    }
                } else {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleScreenAssistantPopover"), object: nil)
                }
            }
        }
    }

    private func updateFeatureShortcutAvailability() {
        let masterEnabled = isRunning && Defaults[.enableShortcuts]
        updateShortcut(.toggleSneakPeek, isEnabled: masterEnabled)
        updateShortcut(.toggleNotchOpen, isEnabled: masterEnabled)
        updateShortcut(.startDemoTimer, isEnabled: masterEnabled && Defaults[.enableTimerFeature])
        updateShortcut(.clipboardHistoryPanel, isEnabled: masterEnabled && Defaults[.enableClipboardManager])
        updateShortcut(.colorPickerPanel, isEnabled: masterEnabled && Defaults[.enableColorPickerFeature])
        updateShortcut(.screenAssistantPanel, isEnabled: masterEnabled && Defaults[.enableScreenAssistant])
        updateShortcut(.toggleTerminalTab, isEnabled: masterEnabled && Defaults[.enableTerminalFeature])
        updateShortcut(.toggleCaffeinate, isEnabled: masterEnabled && Defaults[.enableCaffeinate])
    }

    private func disableAllIslandShortcuts() {
        let names: [KeyboardShortcuts.Name] = [
            .toggleSneakPeek,
            .toggleNotchOpen,
            .startDemoTimer,
            .clipboardHistoryPanel,
            .colorPickerPanel,
            .screenAssistantPanel,
            .toggleTerminalTab,
            .toggleCaffeinate,
        ]
        for name in names {
            KeyboardShortcuts.disable(name)
        }
    }

    private func updateShortcut(_ name: KeyboardShortcuts.Name, isEnabled: Bool) {
        if isEnabled {
            KeyboardShortcuts.enable(name)
        } else {
            KeyboardShortcuts.disable(name)
        }
    }

    // MARK: - Lock Screen Visibility

    private func onScreenLocked() {
        print("Screen locked")
        hideWindowsForLock()
    }

    private func onScreenUnlocked() {
        print("Screen unlocked")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.restoreWindowsAfterLock()
                self.adjustWindowPosition(changeAlpha: true)
            }
        }
    }

    private func hideWindowsForLock() {
        guard !windowsHiddenForLock else { return }
        windowsHiddenForLock = true

        if Defaults[.showOnAllDisplays] {
            for window in windows.values {
                window.alphaValue = 0
                window.orderOut(nil)
            }
        } else if let window = window {
            window.alphaValue = 0
            window.orderOut(nil)
        }
    }

    private func restoreWindowsAfterLock() {
        guard windowsHiddenForLock else { return }
        windowsHiddenForLock = false

        if Defaults[.showOnAllDisplays] {
            for window in windows.values {
                window.orderFrontRegardless()
                window.alphaValue = 1
            }
        } else if let window = window {
            window.orderFrontRegardless()
            window.alphaValue = 1
        }
    }

    // MARK: - Window Creation, Sizing & Positioning

    private func debouncedUpdateWindowSize() {
        windowSizeUpdateWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateWindowSizeIfNeeded()
            }
        }

        windowSizeUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func cleanupWindows(shouldInvert: Bool = false) {
        if shouldInvert ? !Defaults[.showOnAllDisplays] : Defaults[.showOnAllDisplays] {
            for (screen, window) in windows {
                viewModels[screen]?.onViewTeardown?()
                viewModels[screen]?.onViewTeardown = nil
                NotchSpaceManager.shared.notchSpace.windows.remove(window)
                window.close()
            }
            windows.removeAll()
            viewModels.removeAll()
        } else if let window = window {
            vm.onViewTeardown?()
            vm.onViewTeardown = nil
            NotchSpaceManager.shared.notchSpace.windows.remove(window)
            window.close()
            self.window = nil
        }
    }

    private func cleanupAllWindows() {
        for (screen, window) in windows {
            viewModels[screen]?.onViewTeardown?()
            viewModels[screen]?.onViewTeardown = nil
            NotchSpaceManager.shared.notchSpace.windows.remove(window)
            window.close()
        }
        windows.removeAll()
        viewModels.removeAll()

        if let window = window {
            vm.onViewTeardown?()
            vm.onViewTeardown = nil
            NotchSpaceManager.shared.notchSpace.windows.remove(window)
            window.close()
            self.window = nil
        }
    }

    private func syncNotchSpaceMembership() {
        NotchSpaceManager.shared.notchSpace.windows = currentDynamicIslandWindows()
    }

    private func currentDynamicIslandWindows() -> Set<NSWindow> {
        if Defaults[.showOnAllDisplays] {
            return Set(windows.values)
        } else if let window = window {
            return [window]
        }
        return []
    }

    private func reassertDynamicIslandWindowSpacePresence() {
        guard isRunning, !windowsHiddenForLock else { return }

        syncNotchSpaceMembership()

        for window in currentDynamicIslandWindows() {
            window.collectionBehavior = DynamicIslandWindow.pinnedCollectionBehavior
            window.orderFrontRegardless()
        }
    }

    private func createDynamicIslandWindow(for screen: NSScreen, with viewModel: DynamicIslandViewModel)
        -> NSWindow
    {
        let baseSize = calculateRequiredNotchSize()
        let requiredSize = adjustedSizeForScreen(baseSize, screen: screen)
        let roundedWidth = requiredSize.width.rounded()
        let roundedHeight = requiredSize.height.rounded()

        let window = DynamicIslandWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: roundedWidth, height: roundedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.animationBehavior = .none

        window.contentView = FirstMouseHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
                .environmentObject(WebcamManager.shared)
        )

        window.orderFrontRegardless()
        NotchSpaceManager.shared.notchSpace.windows.insert(window)
        return window
    }

    private func positionWindow(_ window: NSWindow, on screen: NSScreen, changeAlpha: Bool = false) {
        if changeAlpha {
            window.alphaValue = 0
        }

        let screenFrame = screen.frame
        let topBleed = notchTopScreenBleed(for: screen.localizedName)
        let centerX = screenFrame.origin.x + (screenFrame.width / 2)
        let roundedWidth = window.frame.width.rounded()
        let roundedHeight = window.frame.height.rounded()
        let newX = (centerX - (roundedWidth / 2)).rounded()
        let newY = (screenFrame.maxY + topBleed - roundedHeight).rounded()

        window.setFrame(
            NSRect(
                x: newX,
                y: newY,
                width: roundedWidth,
                height: roundedHeight
            ),
            display: false
        )

        if changeAlpha {
            window.alphaValue = 1
        }
    }

    private func updateWindowSizeIfNeeded() {
        guard isRunning else { return }
        let requiredSize = calculateRequiredNotchSize()
        let animateResize = shouldAnimateResize(for: requiredSize)
        resizeWindows(to: requiredSize, animated: animateResize, force: false)
    }

    private func updateWindowSizeForTabSwitch() {
        guard isRunning else { return }
        let requiredSize = calculateRequiredNotchSize()
        resizeWindows(to: requiredSize, animated: false, force: true)
    }

    private func calculateRequiredNotchSize() -> CGSize {
        let connectivityState = NetworkConnectivityManager.shared.hudState
        if NetworkConnectivityHUDMetrics.isPresented(
            state: connectivityState,
            notchState: vm.notchState,
            hideOnClosed: vm.hideOnClosed,
            isLocked: LockScreenManager.shared.isLocked
        ),
           let connectivitySize = NetworkConnectivityHUDMetrics.size(
               for: connectivityState,
               closedNotchSize: vm.closedNotchSize,
               effectiveClosedNotchHeight: vm.effectiveClosedNotchHeight
           )
        {
            return addShadowPadding(
                to: connectivitySize,
                isMinimalistic: Defaults[.enableMinimalisticUI]
            )
        }

        // Check if inline sneak peek is showing and notch is closed
        let airPodsListeningModeSneakActive = vm.notchState == .closed &&
            coordinator.sneakPeek.show &&
            coordinator.sneakPeek.type == .bluetoothAudio &&
            coordinator.sneakPeek.value < 0 &&
            AirPodsListeningMode.fromHUDSymbol(coordinator.sneakPeek.icon) != nil
        let isInlineSneakPeekActive = vm.notchState == .closed &&
            Defaults[.enableSneakPeek] &&
            (
                coordinator.expandingView.show &&
                (coordinator.expandingView.type == .music || coordinator.expandingView.type == .timer) &&
                Defaults[.sneakPeekStyles] == .inline ||
                airPodsListeningModeSneakActive
            )

        if isInlineSneakPeekActive {
            let inlineSneakPeekWidth: CGFloat = 460
            return CGSize(width: inlineSneakPeekWidth, height: vm.effectiveClosedNotchHeight)
        }

        if let recordingHUDSize = recordingHUDLayoutForSizing().size(
            closedNotchSize: vm.closedNotchSize,
            effectiveClosedNotchHeight: vm.effectiveClosedNotchHeight
        ) {
            return addShadowPadding(to: recordingHUDSize, isMinimalistic: Defaults[.enableMinimalisticUI])
        }

        // Check for battery HUD expansion
        if vm.notchState == .closed &&
           coordinator.expandingView.show &&
           coordinator.expandingView.type == .battery &&
           Defaults[.showPowerStatusNotifications]
        {
            let batteryModel = BatteryStatusViewModel.shared
            if let kind = batteryModel.activeTemporaryHUDKind {
                let closedNotchHeight = vm.effectiveClosedNotchHeight
                let closedNotchWidth = vm.closedNotchSize.width

                let style: BatteryNotificationStyle = {
                    switch kind {
                    case .charging: return .compact
                    case .lowBattery: return Defaults[.lowBatteryHUDStyle]
                    case .fullBattery: return Defaults[.fullBatteryHUDStyle]
                    }
                }()

                var width = closedNotchWidth
                var height = closedNotchHeight

                switch (kind, style) {
                case (.charging, _), (.lowBattery, .compact), (.fullBattery, .compact):
                    width += 180
                case (.lowBattery, .standard):
                    width += 100
                    height += 75
                case (.fullBattery, .standard):
                    width += 80
                    height += 70
                }

                return addShadowPadding(to: CGSize(width: width, height: height), isMinimalistic: Defaults[.enableMinimalisticUI])
            }
        }

        // Use minimalistic or normal size based on settings
        var baseSize = Defaults[.enableMinimalisticUI]
            ? minimalisticOpenNotchSize(isDynamicIslandMode: shouldUseDynamicIslandMode(for: vm.screen))
            : openNotchSize

        if coordinator.currentView == .timer {
            baseSize.height = 250
        } else if coordinator.currentView == .notes {
            let preferredHeight = coordinator.notesLayoutState.preferredHeight
            baseSize.height = max(baseSize.height, preferredHeight)
        } else if coordinator.currentView == .clipboard {
            baseSize.height = max(baseSize.height, NotesLayoutState.list.preferredHeight)
        } else if coordinator.currentView == .terminal {
            let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
            let maxFraction = Defaults[.terminalMaxHeightFraction]
            baseSize.height = min(screenHeight * maxFraction, max(300, screenHeight * maxFraction))
        }

        baseSize = inlineLyricsAdjustedNotchSize(
            from: baseSize,
            isHomeTabActive: coordinator.currentView == .home
        )

        let adjustedContentSize = statsAdjustedNotchSize(
            from: baseSize,
            isStatsTabActive: coordinator.currentView == .stats,
            secondRowProgress: coordinator.statsSecondRowExpansion
        )
        return addShadowPadding(
            to: adjustedContentSize,
            isMinimalistic: Defaults[.enableMinimalisticUI]
        )
    }

    private func recordingHUDLayoutForSizing() -> RecordingHUDLayout {
        makeRecordingHUDLayout(
            notchState: vm.notchState,
            screenRecordingDetectionEnabled: Defaults[.enableScreenRecordingDetection],
            showRecordingIndicator: Defaults[.showRecordingIndicator],
            hideOnClosed: vm.hideOnClosed,
            isRecording: ScreenRecordingManager.shared.isRecording,
            closedMusicPairingEligible: closedMusicPairingEligibleForSizing(),
            recordingControlMode: Defaults[.recordingControlMode],
            canStopFromHUD: ScreenRecordingManager.shared.shouldShowStopControlsInHUD,
            enableMinimalisticUI: Defaults[.enableMinimalisticUI],
            recordingHoverStyle: Defaults[.recordingHoverStyle],
            suppressHoverExpansion: ScreenRecordingManager.shared.isScreenSharingAppActive,
            expanded: true
        )
    }

    private func closedMusicPairingEligibleForSizing() -> Bool {
        let musicManager = MusicManager.shared
        let hasMusicMetadata = !musicManager.songTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !musicManager.artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasActiveMusicSnapshot = musicManager.isPlaying || (!musicManager.isPlayerIdle && hasMusicMetadata)

        return isClosedMusicPairingEligible(
            notchState: vm.notchState,
            hasActiveMusicSnapshot: hasActiveMusicSnapshot,
            musicLiveActivityEnabled: coordinator.musicLiveActivityEnabled,
            closedMusicContentEnabled: Defaults[.enableMinimalisticUI] || Defaults[.showStandardMediaControls],
            hideOnClosed: vm.hideOnClosed,
            isLocked: LockScreenManager.shared.isLocked,
            isDeferredAfterUnlock: LockScreenManager.shared.shouldDelayPostUnlockMusicHUD
        )
    }

    /// Adds Dynamic Island shadow/top insets on non-notch screens, or top bleed on physical-notch screens.
    private func adjustedSizeForScreen(_ baseSize: CGSize, screen: NSScreen) -> CGSize {
        var adjusted = baseSize
        if shouldUseDynamicIslandMode(for: screen.localizedName) {
            adjusted.width += dynamicIslandShadowInset * 2
            adjusted.height += dynamicIslandTopOffset
        } else {
            adjusted.height += notchTopScreenBleed(for: screen.localizedName)
        }
        return adjusted
    }

    func ensureWindowSize(_ size: CGSize, animated: Bool, force: Bool = false) {
        resizeWindows(to: size, animated: animated, force: force)
    }

    private func resizeWindows(to size: CGSize, animated: Bool, force: Bool) {
        guard size.width > 0, size.height > 0 else { return }

        if Defaults[.showOnAllDisplays] {
            for (screen, window) in windows {
                let screenSize = adjustedSizeForScreen(size, screen: screen)
                if force || window.frame.size != screenSize {
                    resizeWindow(window, on: screen, to: screenSize, animated: animated)
                }
            }
        } else if let window {
            let screen = window.screen
                ?? NSScreen.screens.first { $0.frame.intersects(window.frame) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            guard let screen else { return }
            let screenSize = adjustedSizeForScreen(size, screen: screen)
            if force || window.frame.size != screenSize {
                resizeWindow(window, on: screen, to: screenSize, animated: animated)
            }
        }
    }

    private func resizeWindow(_ window: NSWindow, on screen: NSScreen, to size: CGSize, animated: Bool) {
        let screenFrame = screen.frame
        let topBleed = notchTopScreenBleed(for: screen.localizedName)
        let clampedWidth = min(size.width, screenFrame.width).rounded()
        let maxHeight = screenFrame.height + topBleed
        let clampedHeight = min(size.height, maxHeight).rounded()
        let centerX = screenFrame.midX
        let newX = (centerX - (clampedWidth / 2)).rounded()
        let newY = (screenFrame.maxY + topBleed - clampedHeight).rounded()
        let targetFrame = NSRect(x: newX, y: newY, width: clampedWidth, height: clampedHeight)

        guard window.frame != targetFrame else { return }
        window.setFrame(targetFrame, display: true)
    }

    private func shouldAnimateResize(for newSize: CGSize) -> Bool {
        if Defaults[.enableMinimalisticUI] && !ReminderLiveActivityManager.shared.activeWindowReminders.isEmpty {
            return false
        }
        return true
    }

    private func screenConfigurationDidChange() {
        guard isRunning else { return }
        let currentScreens = NSScreen.screens

        let screensChanged =
            currentScreens.count != previousScreens?.count
            || Set(currentScreens.map { $0.localizedName })
                != Set(previousScreens?.map { $0.localizedName } ?? [])
            || Set(currentScreens.map { $0.frame }) != Set(previousScreens?.map { $0.frame } ?? [])

        previousScreens = currentScreens

        if screensChanged {
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning else { return }
                    self.cleanupWindows()
                    self.adjustWindowPosition()
                }
            }
        }
    }

    func adjustWindowPosition(changeAlpha: Bool = false) {
        guard isRunning else { return }

        if Defaults[.showOnAllDisplays] {
            let currentScreens = Set(NSScreen.screens)

            for screen in windows.keys where !currentScreens.contains(screen) {
                if let window = windows[screen] {
                    viewModels[screen]?.onViewTeardown?()
                    viewModels[screen]?.onViewTeardown = nil
                    window.close()
                    windows.removeValue(forKey: screen)
                    viewModels.removeValue(forKey: screen)
                }
            }

            for screen in currentScreens {
                if windows[screen] == nil {
                    let viewModel = DynamicIslandViewModel(screen: screen.localizedName)
                    let window = createDynamicIslandWindow(for: screen, with: viewModel)

                    windows[screen] = window
                    viewModels[screen] = viewModel
                }

                if let window = windows[screen], let viewModel = viewModels[screen] {
                    positionWindow(window, on: screen, changeAlpha: changeAlpha)

                    if viewModel.notchState == .closed {
                        viewModel.close()
                    }
                }
            }
        } else {
            let selectedScreen: NSScreen

            if let preferredScreen = NSScreen.screens.first(where: {
                $0.localizedName == coordinator.preferredScreen
            }) {
                coordinator.selectedScreen = coordinator.preferredScreen
                selectedScreen = preferredScreen
            } else if Defaults[.automaticallySwitchDisplay], let mainScreen = NSScreen.main {
                coordinator.selectedScreen = mainScreen.localizedName
                selectedScreen = mainScreen
            } else {
                if let window = window {
                    window.alphaValue = 0
                }
                return
            }

            vm.screen = selectedScreen.localizedName
            vm.notchSize = getClosedNotchSize(screen: selectedScreen.localizedName)

            if window == nil {
                window = createDynamicIslandWindow(for: selectedScreen, with: vm)
            }
            if let window = window {
                positionWindow(window, on: selectedScreen, changeAlpha: changeAlpha)

                if vm.notchState == .closed {
                    vm.close()
                }
            }
        }

        syncNotchSpaceMembership()
    }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x)
        hasher.combine(origin.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
        return lhs.origin == rhs.origin && lhs.size == rhs.size
    }
}

@MainActor
final class MediaControlsStateCoordinator {
    static let shared = MediaControlsStateCoordinator()

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let masterPublisher = Defaults.publisher(.showStandardMediaControls)
        let minimalisticPublisher = Defaults.publisher(.enableMinimalisticUI)

        Publishers.CombineLatest(masterPublisher, minimalisticPublisher)
            .receive(on: RunLoop.main)
            .sink { [weak self] masterChange, minimalisticChange in
                self?.handleStateChange(
                    showStandard: masterChange.newValue,
                    minimalistic: minimalisticChange.newValue
                )
            }
            .store(in: &cancellables)
    }

    private func handleStateChange(showStandard: Bool, minimalistic: Bool) {
        if !showStandard && !minimalistic {
            cacheAndDisableMusicLiveActivity()
        } else {
            restoreMusicLiveActivity(clearCache: showStandard)
        }

        if showStandard {
            restoreLockScreenPanelIfNeeded()
            restoreMusicControlWindowIfNeeded()
        } else {
            cacheAndDisableLockScreenPanel()
            cacheAndDisableMusicControlWindow()
        }
    }

    private func cacheAndDisableMusicLiveActivity() {
        if Defaults[.cachedMusicLiveActivityPreference] == nil {
            Defaults[.cachedMusicLiveActivityPreference] = DynamicIslandViewCoordinator.shared.musicLiveActivityEnabled
        }

        if DynamicIslandViewCoordinator.shared.musicLiveActivityEnabled {
            DynamicIslandViewCoordinator.shared.musicLiveActivityEnabled = false
        }
    }

    private func restoreMusicLiveActivity(clearCache: Bool) {
        guard let cached = Defaults[.cachedMusicLiveActivityPreference] else { return }

        if DynamicIslandViewCoordinator.shared.musicLiveActivityEnabled != cached {
            DynamicIslandViewCoordinator.shared.musicLiveActivityEnabled = cached
        }

        if clearCache {
            Defaults[.cachedMusicLiveActivityPreference] = nil
        }
    }

    private func cacheAndDisableLockScreenPanel() {
        if Defaults[.cachedLockScreenMediaWidgetPreference] == nil {
            Defaults[.cachedLockScreenMediaWidgetPreference] = Defaults[.enableLockScreenMediaWidget]
        }

        if Defaults[.enableLockScreenMediaWidget] {
            Defaults[.enableLockScreenMediaWidget] = false
            LockScreenPanelManager.shared.hidePanel()
        }
    }

    private func restoreLockScreenPanelIfNeeded() {
        guard let cached = Defaults[.cachedLockScreenMediaWidgetPreference] else { return }
        Defaults[.enableLockScreenMediaWidget] = cached
        Defaults[.cachedLockScreenMediaWidgetPreference] = nil
    }

    private func cacheAndDisableMusicControlWindow() {
        if Defaults[.cachedMusicControlWindowPreference] == nil {
            Defaults[.cachedMusicControlWindowPreference] = Defaults[.musicControlWindowEnabled]
        }

        if Defaults[.musicControlWindowEnabled] {
            Defaults[.musicControlWindowEnabled] = false
        }

        MusicControlWindowManager.shared.hide()
    }

    private func restoreMusicControlWindowIfNeeded() {
        guard let cached = Defaults[.cachedMusicControlWindowPreference] else { return }
        Defaults[.musicControlWindowEnabled] = cached
        Defaults[.cachedMusicControlWindowPreference] = nil
    }
}
