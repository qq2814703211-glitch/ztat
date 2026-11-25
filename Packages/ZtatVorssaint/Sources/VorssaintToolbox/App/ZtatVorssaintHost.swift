// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Public host API bridging VorssaintToolbox into ztat's unified Liquid Glass Hub and Settings window.

import AppKit
import ApplicationServices
import Combine
import SwiftUI
import ZtatCore

@MainActor
public final class ZtatVorssaintHost: ObservableObject {
    public static let shared = ZtatVorssaintHost()

    private var isStarted = false
    private var statusController: StatusItemController?
    private var cancellables = Set<AnyCancellable>()
    private var activeOpenSettingsHandler: (() -> Void)?

    private init() {}

    /// Boot enabled non-overlapping toolbox services lazily. Does NOT create standalone status items.
    public func start() {
        guard !isStarted else { return }
        isStarted = true

        Defaults.register()
        AppAppearanceController.shared.apply()
        GlobalShortcut.startObservingKeyboardLayout()
        Self.boundAccessibilityWaits()
        _ = AssistiveKeyboard.isRunning

        DispatchQueue.global(qos: .utility).async {
            RecorderGIFWorkspace.sweep()
        }

        // Prepare clean first-run toolbox availability without launching Vorssaint's standalone onboarding modal.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: DefaultsKey.hasOnboarded) {
            FeaturePreset.prepareFirstRunAvailability(in: defaults)
            defaults.set(true, forKey: DefaultsKey.hasOnboarded)
        }
        // Ensure excluded overlapping features stay disabled even if legacy defaults exist.
        for feature in AppFeature.allCases where feature.isExcludedInZtat {
            if defaults.bool(forKey: feature.availabilityKey) {
                defaults.set(false, forKey: feature.availabilityKey)
            }
        }

        if BrightnessService.hasDisplaysToRestore {
            FeatureRuntime.shared.registerStartedFeature(.brightness)
            BrightnessService.shared.restoreDisplaysLeftOff()
        }

        HorizontalWheelScrolling.install()

        // StatusItemController creates ZERO main or metric status items in ztat;
        // it only manages the strictly opt-in Clipboard Preview menu bar item (off by default).
        let controller = StatusItemController()
        controller.onClipboardPreviewClick = {
            FeatureRuntime.shared.registerStartedFeature(.clipboardHistory)
            ClipboardHistoryService.shared.toggleHistoryWindow()
        }
        statusController = controller

        SystemShortcutTakeover.recoverIfNeeded(keeping: AppSwitcher.launchTakeoverIDs())
        FeatureRuntime.shared.syncAtLaunch()

        // Re-sync only non-overlapping features when TCC permissions flip.
        Permissions.shared.$accessibility
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                FeatureRuntime.shared.sync([
                    .scrollInverter, .scrollHorizontal, .scrollZoom, .focusFollowsMouse,
                    .smoothScroll, .linearScroll, .scrollSpeed, .mouseNavigation,
                    .mouseButtonShortcuts, .middleClick, .mouseClickDebounce,
                    .keyboardDebounce, .textSnippets, .superKey, .quitWindowProtection,
                    .switcher, .dockPreview, .dockClick, .windowMaximizer, .windowLayout,
                    .autoQuit, .spacesOrder, .finderCutPaste, .finderRename, .shelf,
                    .mixer, .brightness, .radialMenu, .notch, .notchNotifications,
                ])
            }
            .store(in: &cancellables)

        Permissions.shared.$fullDiskAccess
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                FeatureRuntime.shared.sync([.uninstaller])
            }
            .store(in: &cancellables)

        Permissions.shared.$screenRecording
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                FeatureRuntime.shared.sync([.dockPreview, .screenRecorder])
            }
            .store(in: &cancellables)
    }

    /// Stop ONLY services that were actually started during this session.
    public func stop() {
        guard isStarted else { return }
        isStarted = false

        cancellables.removeAll()
        statusController?.stop()
        statusController = nil
        FeatureRuntime.shared.stopStartedServices()
    }

    /// Reconcile opt-in auxiliary UI if needed when app is reopened.
    public func handleReopen() {
        guard isStarted else { return }
        statusController?.reconcileOptInItems()
        if AppFeature.notch.isAvailable,
           UserDefaults.standard.bool(forKey: DefaultsKey.notchEnabled) {
            FeatureRuntime.shared.registerStartedFeature(.notch)
            NotchService.shared.syncWithPreferences()
        }
    }

    /// Compact 356pt SwiftUI view hosted inside ztat's unified Liquid Glass Hub "工具箱" tab.
    public func makeToolboxPanelView(onOpenSettings: (() -> Void)? = nil) -> AnyView {
        if let onOpenSettings {
            activeOpenSettingsHandler = onOpenSettings
        }
        return AnyView(
            ZtatToolboxPanelView(onOpenSettings: { [weak self] in
                if let onOpenSettings {
                    onOpenSettings()
                } else {
                    self?.requestOpenSettings()
                }
            })
        )
    }

    /// Embedded Vorssaint Feature Hub & Settings view for ztat's unified Settings window
    /// (with all overlapping Monitor / FanControl / KeepAwake / Vorssaint Update sections removed).
    public func makeSettingsView() -> AnyView {
        if !FeatureVisibilitySupport.isPageVisible(SettingsRouter.shared.page, isAvailable: { $0.isAvailable })
            || SettingsRouter.shared.page == .general {
            SettingsRouter.shared.page = .features
        }
        return AnyView(SettingsView(embeddedInZtat: true))
    }

    /// Internal bridge used by embedded Vorssaint views (Notch, SnippetLibrary, Toolbox panel,
    /// CommandBar, RadialMenu, Cleaner) to open ztat's unified Settings window focused on Toolbox.
    func requestOpenSettings() {
        if let handler = activeOpenSettingsHandler {
            handler()
        } else {
            NotificationCenter.default.post(name: .ztatOpenSettings, object: ZtatSettingsSection.toolbox)
        }
    }

    /// Internal bridge used by TrashAppWatcher and CommandBar to open the Uninstaller page
    /// inside ztat's unified Settings window.
    func openUninstaller(for appURL: URL, trashMove: UninstallerSupport.TrashMove? = nil) {
        let uninstaller = AppUninstaller.shared
        guard AppFeature.uninstaller.isAvailable,
              uninstaller.select(appURL: appURL, trashMove: trashMove) || (trashMove == nil && uninstaller.isRemoving)
        else { return }
        FeatureRuntime.shared.registerStartedFeature(.uninstaller)
        SettingsRouter.shared.page = .uninstaller
        requestOpenSettings()
    }

    private static func boundAccessibilityWaits() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }
}

// MARK: - Compact 356pt Toolbox Hub Panel

private enum ZtatToolboxSubTab: String, CaseIterable, Identifiable {
    case tools
    case mixer
    case features

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tools: return ZtatL10n.tr("快捷工具", "Tools")
        case .mixer: return ZtatL10n.tr("音量混音", "Mixer")
        case .features: return ZtatL10n.tr("功能开关", "Features")
        }
    }

    var symbol: String {
        switch self {
        case .tools: return "wand.and.stars"
        case .mixer: return "speaker.wave.2.fill"
        case .features: return "switch.2"
        }
    }
}

private struct ZtatToolboxPanelView: View {
    let onOpenSettings: () -> Void

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @State private var selectedTab: ZtatToolboxSubTab = .tools

    var body: some View {
        VStack(spacing: 10) {
            subTabPicker

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    switch selectedTab {
                    case .tools:
                        ZtatToolboxQuickToolsContent(
                            onJumpToMixer: { selectedTab = .mixer },
                            onOpenSettingsPage: openSettingsPage
                        )
                    case .mixer:
                        ZtatToolboxFullMixerContent()
                    case .features:
                        ZtatToolboxQuickFeaturesContent(onOpenSettingsPage: openSettingsPage)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footerBar
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(width: ZtatBrand.hubPanelWidth)
    }

    private var subTabPicker: some View {
        HStack(spacing: 4) {
            ForEach(ZtatToolboxSubTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.horizontal, 12)
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Text(ZtatL10n.tr(
                "\(features.availableCount)/\(features.installableCount) 项工具可用",
                "\(features.availableCount)/\(features.installableCount) tools enabled"
            ))
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .monospacedDigit()

            Spacer(minLength: 6)

            Button {
                SettingsRouter.shared.page = .features
                onOpenSettings()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(ZtatL10n.tr("工具箱设置…", "Toolbox Settings…"))
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private func openSettingsPage(_ page: SettingsPage) {
        SettingsRouter.shared.page = page
        onOpenSettings()
    }
}

// MARK: - Sub-Tab 1: Quick Tools & Standout Controls

private struct ZtatToolboxQuickToolsContent: View {
    let onJumpToMixer: () -> Void
    let onOpenSettingsPage: (SettingsPage) -> Void

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var recorder = ScreenRecorderService.shared
    @ObservedObject private var cleaning = CleaningModeManager.shared
    @ObservedObject private var micMute = MicMuteService.shared
    @ObservedObject private var extraBrightness = ExtraBrightnessService.shared
    @ObservedObject private var mixer = AppVolumeMixer.shared

    @AppStorage(DefaultsKey.notchEnabled) private var notchEnabled = false
    @AppStorage(DefaultsKey.extraBrightnessEnabled) private var extraBrightnessEnabled = false
    @AppStorage(DefaultsKey.extraBrightnessLevel) private var extraBrightnessLevel = 100
    @AppStorage(DefaultsKey.clipboardHistoryEnabled) private var clipboardEnabled = false
    @AppStorage(DefaultsKey.shelfEnabled) private var shelfEnabled = false

    private let quickGridColumns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. Capture & Quick Action 3x2 Grid
            ZtatToolboxCard(title: ZtatL10n.tr("快捷操作", "Quick Actions")) {
                LazyVGrid(columns: quickGridColumns, spacing: 6) {
                    ZtatActionTile(
                        symbol: "camera.viewfinder",
                        title: ZtatL10n.tr("截图", "Screenshot"),
                        active: false
                    ) {
                        ensureAvailable(.screenshot)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            ScreenshotService.shared.capture()
                        }
                    }

                    ZtatActionTile(
                        symbol: recorder.isRecording ? "stop.circle.fill" : "record.circle",
                        title: recorder.isRecording
                            ? ZtatL10n.tr("停止录屏", "Stop Rec")
                            : ZtatL10n.tr("录屏", "Record"),
                        active: recorder.isRecording,
                        tint: .red
                    ) {
                        ensureAvailable(.screenRecorder)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            ScreenRecorderService.shared.toggle()
                        }
                    }

                    ZtatActionTile(
                        symbol: "text.viewfinder",
                        title: ZtatL10n.tr("屏幕 OCR", "OCR"),
                        active: false
                    ) {
                        ensureAvailable(.screenOCR)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            ScreenTextService.shared.capture()
                        }
                    }

                    ZtatActionTile(
                        symbol: "eyedropper",
                        title: ZtatL10n.tr("取色器", "Color"),
                        active: false
                    ) {
                        ensureAvailable(.colorPicker)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            ColorSamplerService.shared.pick()
                        }
                    }

                    ZtatActionTile(
                        symbol: "bubbles.and.sparkles",
                        title: ZtatL10n.tr("清洁锁屏", "Clean"),
                        active: cleaning.isActive,
                        tint: .cyan
                    ) {
                        ensureAvailable(.cleaningMode)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            CleaningModeManager.shared.toggle()
                        }
                    }

                    ZtatActionTile(
                        symbol: "command",
                        title: ZtatL10n.tr("命令栏", "Cmd Bar"),
                        active: false
                    ) {
                        ensureAvailable(.commandBar)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            CommandBarService.shared.show()
                        }
                    }
                }
            }

            // 2. Per-App Volume Mixer (>100% Boost) Quick Card
            ZtatToolboxCard(
                title: ZtatL10n.tr("应用混音 (>100%)", "App Mixer (>100%)"),
                trailingTitle: ZtatL10n.tr("全部", "All"),
                trailingAction: onJumpToMixer
            ) {
                if !AppVolumeMixer.isSupported {
                    Text(l10n.s.mixerUnavailable)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if mixer.apps.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(ZtatL10n.tr("当前无活跃音频应用", "No active audio apps"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(mixer.apps.prefix(3))) { app in
                            ZtatMiniMixerRow(app: app, mixer: mixer)
                        }
                        if mixer.apps.count > 3 {
                            Button(action: onJumpToMixer) {
                                Text(ZtatL10n.tr(
                                    "查看全部 \(mixer.apps.count) 个音频应用…",
                                    "Show all \(mixer.apps.count) audio apps…"
                                ))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }

            // 3. Clipboard / Shelf / Snippets / Mic Mute Bar
            ZtatToolboxCard(title: ZtatL10n.tr("效率浮窗", "Productivity")) {
                HStack(spacing: 6) {
                    ZtatPillButton(
                        symbol: "doc.on.clipboard",
                        title: ZtatL10n.tr("剪贴板", "Clipboard")
                    ) {
                        ensureAvailable(.clipboardHistory)
                        if !clipboardEnabled {
                            clipboardEnabled = true
                            ClipboardHistoryService.shared.syncWithPreferences()
                        }
                        ClipboardHistoryService.shared.showHistoryWindow()
                    }

                    ZtatPillButton(
                        symbol: "tray.full",
                        title: ZtatL10n.tr("暂存架", "Shelf")
                    ) {
                        ensureAvailable(.shelf)
                        if !shelfEnabled {
                            shelfEnabled = true
                            ShelfService.shared.syncWithPreferences()
                        }
                        ShelfService.shared.toggleDocked()
                    }

                    ZtatPillButton(
                        symbol: "text.append",
                        title: ZtatL10n.tr("短语库", "Snippets")
                    ) {
                        ensureAvailable(.textSnippets)
                        SnippetLibraryService.shared.toggle()
                    }

                    ZtatPillButton(
                        symbol: micMute.isMuted ? "mic.slash.fill" : "mic.fill",
                        title: ZtatL10n.tr("闭麦", "Mic"),
                        highlighted: micMute.isMuted,
                        tint: .red
                    ) {
                        ensureAvailable(.micMute)
                        MicMuteService.shared.toggle()
                    }
                }
            }

            // 4. Standout Toggles: Dynamic Island & XDR Extra Brightness
            ZtatToolboxCard(title: ZtatL10n.tr("增强模式", "Enhancements")) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "macbook")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(notchEnabled && AppFeature.notch.isAvailable ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ZtatL10n.tr("灵动岛 (AI / 媒体 / 保活)", "Dynamic Island"))
                                .font(.system(size: 11.5, weight: .medium))
                            Text(ZtatL10n.tr("显示媒体控制、AI 用量与保活状态", "Media, AI agents & Power Guard"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Toggle("", isOn: Binding(
                            get: { AppFeature.notch.isAvailable && notchEnabled },
                            set: { on in
                                if on { ensureAvailable(.notch) }
                                notchEnabled = on
                                FeatureRuntime.shared.registerStartedFeature(.notch)
                                NotchService.shared.syncWithPreferences()
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    Divider().opacity(0.45)

                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "sun.max.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(extraBrightnessEnabled && AppFeature.extraBrightness.isAvailable ? .orange : .secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ZtatL10n.tr("XDR 超高亮度", "XDR Extra Brightness"))
                                    .font(.system(size: 11.5, weight: .medium))
                                Text(extraBrightness.supported
                                     ? ZtatL10n.tr("突破常规亮度上限 (\(extraBrightnessLevel)%)", "EDR headroom boost (\(extraBrightnessLevel)%)")
                                     : ZtatL10n.tr("需要内置 XDR 显示屏", "Requires built-in XDR display"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Toggle("", isOn: Binding(
                                get: { AppFeature.extraBrightness.isAvailable && extraBrightnessEnabled },
                                set: { on in
                                    if on { ensureAvailable(.extraBrightness) }
                                    extraBrightnessEnabled = on
                                    FeatureRuntime.shared.registerStartedFeature(.extraBrightness)
                                    ExtraBrightnessService.shared.syncWithPreferences()
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!extraBrightness.supported && !extraBrightnessEnabled)
                        }

                        if AppFeature.extraBrightness.isAvailable && extraBrightnessEnabled && extraBrightness.supported {
                            HStack(spacing: 8) {
                                Slider(
                                    value: Binding(
                                        get: { Double(extraBrightnessLevel) },
                                        set: { newVal in
                                            extraBrightnessLevel = Int(newVal.rounded())
                                            ExtraBrightnessService.shared.levelDidChange()
                                        }
                                    ),
                                    in: 10...100,
                                    step: 5
                                )
                                .controlSize(.small)
                                Text("+\(extraBrightnessLevel)%")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.orange)
                                    .frame(width: 38, alignment: .trailing)
                            }
                        }
                    }
                }
            }

            // 5. System Tools Shortcuts
            ZtatToolboxCard(title: ZtatL10n.tr("系统工具", "System Utilities")) {
                LazyVGrid(columns: quickGridColumns, spacing: 6) {
                    ZtatMiniLinkButton(symbol: "trash", title: ZtatL10n.tr("卸载器", "Uninstall")) {
                        ensureAvailable(.uninstaller)
                        onOpenSettingsPage(.uninstaller)
                    }
                    ZtatMiniLinkButton(symbol: "sparkles", title: ZtatL10n.tr("垃圾清理", "Cleaner")) {
                        ensureAvailable(.cleaner)
                        onOpenSettingsPage(.cleaner)
                    }
                    ZtatMiniLinkButton(symbol: "shippingbox", title: "Homebrew") {
                        ensureAvailable(.homebrew)
                        onOpenSettingsPage(.homebrew)
                    }
                    ZtatMiniLinkButton(symbol: "network", title: ZtatL10n.tr("端口管理", "Ports")) {
                        ensureAvailable(.portManager)
                        onOpenSettingsPage(.portManager)
                    }
                    ZtatMiniLinkButton(symbol: "xmark.octagon", title: ZtatL10n.tr("结束进程", "Kill Proc")) {
                        ensureAvailable(.killProcess)
                        onOpenSettingsPage(.killProcess)
                    }
                    ZtatMiniLinkButton(symbol: "arrow.down.app", title: ZtatL10n.tr("应用更新", "Updates")) {
                        ensureAvailable(.appUpdates)
                        onOpenSettingsPage(.appUpdates)
                    }
                }
            }
        }
        .onAppear {
            FeatureRuntime.shared.registerStartedFeature(.mixer)
            mixer.refreshApps()
            extraBrightness.syncWithPreferences()
        }
    }

    private func ensureAvailable(_ feature: AppFeature) {
        if !feature.isAvailable {
            FeatureRuntime.shared.setAvailable([feature], true)
        }
        FeatureRuntime.shared.registerStartedFeature(feature)
    }
}

// MARK: - Sub-Tab 2: Full Per-App Volume Mixer (>100% Boost)

private struct ZtatToolboxFullMixerContent: View {
    var body: some View {
        MixerSection(collapsible: false)
            .onAppear {
                if !AppFeature.mixer.isAvailable {
                    FeatureRuntime.shared.setAvailable([.mixer], true)
                }
                FeatureRuntime.shared.registerStartedFeature(.mixer)
                AppVolumeMixer.shared.syncWithPreferences()
                AppVolumeMixer.shared.refreshApps()
            }
    }
}

// MARK: - Sub-Tab 3: Quick Feature Toggles

private struct ZtatToolboxQuickFeaturesContent: View {
    let onOpenSettingsPage: (SettingsPage) -> Void

    @ObservedObject private var features = FeatureRuntime.shared
    @AppStorage(DefaultsKey.clipboardHistoryEnabled) private var clipboardEnabled = false
    @AppStorage(DefaultsKey.urlCleanerEnabled) private var urlCleanerEnabled = false
    @AppStorage(DefaultsKey.shelfEnabled) private var shelfEnabled = false
    @AppStorage(DefaultsKey.switcherEnabled) private var switcherEnabled = false
    @AppStorage(DefaultsKey.dockPreviewEnabled) private var dockPreviewEnabled = false
    @AppStorage(DefaultsKey.windowEdgeSnapEnabled) private var windowEdgeSnapEnabled = false
    @AppStorage(DefaultsKey.focusFollowsMouseEnabled) private var focusFollowsMouseEnabled = false
    @AppStorage(DefaultsKey.quitProtectionQuitEnabled) private var quitProtectionEnabled = false
    @AppStorage(DefaultsKey.bluetoothSleepEnabled) private var bluetoothSleepEnabled = false
    @AppStorage(DefaultsKey.notchEnabled) private var notchEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZtatToolboxCard(title: ZtatL10n.tr("窗口与桌面", "Windows & Dock")) {
                VStack(spacing: 6) {
                    quickToggleRow(symbol: "rectangle.3.group", title: ZtatL10n.tr("窗口布局 / 贴边吸附", "Window Layout & Snap"),
                                   feature: .windowLayout, isOn: $windowEdgeSnapEnabled, page: .windowLayout)
                    Divider().opacity(0.4)
                    quickToggleRow(symbol: "macwindow.on.rectangle", title: ZtatL10n.tr("窗口切换器", "App Switcher"),
                                   feature: .switcher, isOn: $switcherEnabled, page: .switcher)
                    Divider().opacity(0.4)
                    quickToggleRow(symbol: "dock.rectangle", title: ZtatL10n.tr("Dock 窗口预览", "Dock Preview"),
                                   feature: .dockPreview, isOn: $dockPreviewEnabled, page: .dock)
                    Divider().opacity(0.4)
                    quickToggleRow(symbol: "cursorarrow.motionlines", title: ZtatL10n.tr("焦点跟随鼠标", "Focus Follows Mouse"),
                                   feature: .focusFollowsMouse, isOn: $focusFollowsMouseEnabled, page: .mouse)
                    Divider().opacity(0.4)
                    quickToggleRow(symbol: "hand.raised", title: ZtatL10n.tr("防误退保护", "Quit Protection"),
                                   feature: .quitWindowProtection, isOn: $quitProtectionEnabled, page: .quitProtection)
                }
            }

            ZtatToolboxCard(title: ZtatL10n.tr("剪贴板、灵动岛与外设", "Clipboard, Island & Display")) {
                VStack(spacing: 6) {
                    quickToggleRow(symbol: "doc.on.clipboard", title: ZtatL10n.tr("剪贴板历史", "Clipboard History"),
                                   feature: .clipboardHistory, isOn: $clipboardEnabled, page: .clipboard)
                    Divider().opacity(0.4)
                    quickToggleRow(symbol: "link", title: ZtatL10n.tr("URL 追踪参数清理", "URL Cleaner"),
                                   feature: .urlCleaner, isOn: $urlCleanerEnabled, page: .urlCleaner)
                    Divider().opacity(0.4)
                    quickToggleRow(symbol: "tray.full", title: ZtatL10n.tr("文件暂存架", "File Shelf"),
                                   feature: .shelf, isOn: $shelfEnabled, page: .shelf)
                    Divider().opacity(0.4)
                    quickToggleRow(symbol: "macbook", title: ZtatL10n.tr("灵动岛", "Dynamic Island"),
                                   feature: .notch, isOn: $notchEnabled, page: .notch)
                    Divider().opacity(0.4)
                    quickToggleRow(symbol: "wave.3.right.circle", title: ZtatL10n.tr("休眠关闭蓝牙", "Bluetooth Sleep"),
                                   feature: .bluetoothSleep, isOn: $bluetoothSleepEnabled, page: .energy)
                }
            }
        }
    }

    private func quickToggleRow(symbol: String,
                                title: String,
                                feature: AppFeature,
                                isOn: Binding<Bool>,
                                page: SettingsPage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(feature.isAvailable && isOn.wrappedValue ? Color.accentColor : .secondary)
                .frame(width: 18)

            Button {
                onOpenSettingsPage(page)
            } label: {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { feature.isAvailable && isOn.wrappedValue },
                set: { enabled in
                    if enabled && !feature.isAvailable {
                        FeatureRuntime.shared.setAvailable([feature], true)
                    }
                    isOn.wrappedValue = enabled
                    FeatureRuntime.shared.sync([feature])
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

// MARK: - Reusable Compact Subviews

private struct ZtatToolboxCard<Content: View>: View {
    let title: String
    var trailingTitle: String? = nil
    var trailingAction: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailingTitle, let trailingAction {
                    Button(trailingTitle, action: trailingAction)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .buttonStyle(.plain)
                }
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
    }
}

private struct ZtatActionTile: View {
    let symbol: String
    let title: String
    let active: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active ? tint : .primary)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(active ? tint : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? tint.opacity(0.16) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? tint.opacity(0.45) : Color.clear, lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ZtatPillButton: View {
    let symbol: String
    let title: String
    var highlighted: Bool = false
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(highlighted ? tint : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(highlighted ? tint.opacity(0.16) : Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ZtatMiniLinkButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ZtatMiniMixerRow: View {
    let app: MixerApp
    @ObservedObject var mixer: AppVolumeMixer

    var body: some View {
        let percent = MixerRoutingSupport.displayPercent(forVolume: app.volume)
        let isBoosted = percent > 100
        let isMuted = app.volume <= 0.001
        let appIcon = NSRunningApplication(processIdentifier: app.ownerPid)?.icon
        HStack(spacing: 7) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 12))
                    .frame(width: 16, height: 16)
            }

            Text(app.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)

            Slider(
                value: Binding(
                    get: { app.volume },
                    set: { mixer.setVolume($0, for: app) }
                ),
                in: 0...AppVolumeMixer.maxVolume
            )
            .controlSize(.small)
            .tint(isBoosted ? .orange : .accentColor)

            Text("\(percent)%")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isBoosted ? .orange : .secondary)
                .frame(width: 36, alignment: .trailing)

            Button {
                mixer.toggleMute(app)
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(isMuted ? .red : .secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
        }
    }
}
