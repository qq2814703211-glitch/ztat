// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Public host API bridging VorssaintToolbox into ztat's unified Liquid Glass Hub and Settings window.

import AppKit
import ApplicationServices
import Combine
import SwiftUI
import ZtatCore

/// Public sidebar descriptors flattening Vorssaint toolbox categories directly into ztat's single Unified Settings sidebar.
public struct ZtatToolboxNavItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let icon: String

    public init(id: String, title: String, icon: String) {
        self.id = id
        self.title = title
        self.icon = icon
    }
}

public struct ZtatToolboxNavGroup: Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let items: [ZtatToolboxNavItem]

    public init(id: Int, title: String, items: [ZtatToolboxNavItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

@MainActor
public final class ZtatVorssaintHost: ObservableObject {
    public static let shared = ZtatVorssaintHost()

    @Published public private(set) var navigationRevision: Int = 0
    @Published public private(set) var activeToolboxItemID: String = "page:features"

    private var isStarted = false
    private var statusController: StatusItemController?
    private var cancellables = Set<AnyCancellable>()
    private var notificationObservers: [NSObjectProtocol] = []
    private var activeOpenSettingsHandler: (() -> Void)?

    private init() {}

    /// MUST be called at process startup BEFORE NSApplication launches so detached cleanup helpers
    /// (such as `--mouse-acceleration-cleanup`) restore state and exit cleanly without spawning a rogue GUI instance.
    public static func handleStartupHelperArgumentsIfNeeded() {
        MouseAccelerationGuard.runIfRequestedAndExit()
    }

    /// Boot enabled non-overlapping toolbox services lazily. Does NOT create standalone status items.
    public func start() {
        guard !isStarted else { return }
        isStarted = true

        Defaults.register()
        syncLanguageFromUnifiedStore()
        syncAppearanceFromUnifiedStore()
        AppAppearanceController.shared.apply()
        GlobalShortcut.startObservingKeyboardLayout()
        Self.boundAccessibilityWaits()
        SpacesOrderHold.recoverIfNeeded()
        _ = AssistiveKeyboard.isRunning

        DispatchQueue.global(qos: .utility).async {
            RecorderGIFWorkspace.sweep()
        }

        // Prepare clean first-run toolbox availability without launching standalone onboarding modal.
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

        // Wire menu bar docked Shelf anchor to ztat's primary menu bar status item.
        ShelfService.statusItemFrameProvider = {
            if Thread.isMainThread {
                return MainActor.assumeIsolated {
                    ZtatHostBridge.shared.primaryStatusItemFrame()
                }
            }
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    ZtatHostBridge.shared.primaryStatusItemFrame()
                }
            }
        }

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
                    .mixer, .musicBlock, .brightness, .radialMenu,
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

        // Refresh live TCC state whenever the non-activating Hub panel opens so permission badges never lag.
        NotificationCenter.default.publisher(for: .ztatHubPanelVisibilityDidChange)
            .receive(on: DispatchQueue.main)
            .sink { note in
                if (note.userInfo?["visible"] as? Bool) == true {
                    Permissions.shared.refreshActivePermissions()
                }
            }
            .store(in: &cancellables)

        FeatureRuntime.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.navigationRevision &+= 1 }
            .store(in: &cancellables)

        L10n.shared.$language
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.navigationRevision &+= 1 }
            .store(in: &cancellables)

        // Two-way sidebar selection sync: publish activeToolboxItemID whenever SettingsRouter navigates internally.
        SettingsRouter.shared.$requestID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let resolved = self.currentSelectedToolboxItemID()
                if self.activeToolboxItemID != resolved {
                    self.activeToolboxItemID = resolved
                }
            }
            .store(in: &cancellables)

        let nc = NotificationCenter.default
        notificationObservers.append(
            nc.addObserver(forName: .ztatLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncLanguageFromUnifiedStore()
                }
            }
        )
        notificationObservers.append(
            nc.addObserver(forName: .ztatAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncAppearanceFromUnifiedStore()
                }
            }
        )
    }

    /// Stop ONLY services that were actually started during this session.
    public func stop() {
        guard isStarted else { return }
        isStarted = false

        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        notificationObservers.removeAll()
        cancellables.removeAll()
        statusController?.stop()
        statusController = nil
        FeatureRuntime.shared.stopStartedServices()
    }

    private func syncLanguageFromUnifiedStore() {
        let pref = ZtatLocalizationStore.shared.preference
        let target: AppLanguage
        if let code = pref.toolboxLanguageCode, let lang = AppLanguage(rawValue: code) {
            target = lang
        } else {
            target = .systemDefault
        }
        if L10n.shared.language != target {
            L10n.shared.language = target
        }
    }

    private func syncAppearanceFromUnifiedStore() {
        let target: AppAppearance
        switch ZtatAppearanceStore.shared.appearance {
        case .system: target = .system
        case .light: target = .light
        case .dark: target = .dark
        }
        if AppAppearanceController.shared.appearance != target {
            AppAppearanceController.shared.appearance = target
        }
    }

    /// Dedicated Permissions & Privacy Portal hosted directly under ztat's Core Settings sidebar.
    public func makePermissionsPortalView() -> AnyView {
        AnyView(ZtatPermissionsPortalView())
    }

    /// Reconcile opt-in auxiliary UI if needed when app is reopened.
    public func handleReopen() {
        guard isStarted else { return }
        statusController?.reconcileOptInItems()
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

    private static func stableSidebarID(for id: SettingsSidebarItem.ID) -> String {
        switch id {
        case .page(let page):
            return "page:\(String(describing: page))"
        case .feature(let feature):
            return "feature:\(feature.rawValue)"
        case .setting(let anchor):
            return "setting:\(String(describing: anchor))"
        }
    }

    private func rawSidebarSections() -> [SettingsSidebarSection] {
        let superKeyRaw = UserDefaults.standard.string(forKey: DefaultsKey.superKeySource) ?? SuperKeySource.capsLock.rawValue
        return SettingsDirectory.sidebarSections(
            L10n.shared.s,
            language: L10n.shared.language,
            superKeySource: SuperKeySource.sanitized(superKeyRaw),
            isAvailable: { FeatureRuntime.shared.isAvailable($0) }
        )
    }

    /// Flat sidebar groups of deduplicated Vorssaint toolbox pages for ztat's single Unified Settings sidebar.
    public func sidebarGroups() -> [ZtatToolboxNavGroup] {
        rawSidebarSections().compactMap { section in
            let mapped = section.items.map { item -> ZtatToolboxNavItem in
                let title: String
                if case .page(.general) = item.id {
                    title = ZtatL10n.tr("浮窗玻璃材质", "Glass & Visual Effects")
                } else {
                    title = item.title
                }
                return ZtatToolboxNavItem(
                    id: Self.stableSidebarID(for: item.id),
                    title: title,
                    icon: item.icon
                )
            }
            guard !mapped.isEmpty else { return nil }
            return ZtatToolboxNavGroup(id: section.id, title: section.title, items: mapped)
        }
    }

    public func defaultToolboxItemID() -> String {
        let items = rawSidebarSections().flatMap(\.items)
        if let featuresItem = items.first(where: { $0.id == .page(.features) }) {
            return Self.stableSidebarID(for: featuresItem.id)
        }
        if let first = items.first {
            return Self.stableSidebarID(for: first.id)
        }
        return "page:features"
    }

    public func currentSelectedToolboxItemID() -> String {
        let items = rawSidebarSections().flatMap(\.items)
        let router = SettingsRouter.shared
        if let selected = SettingsSidebarSupport.selection(
            for: router.destination,
            in: items,
            preferredID: router.sidebarFeature.map { .feature($0) }
        ) {
            return Self.stableSidebarID(for: selected)
        }
        return defaultToolboxItemID()
    }

    public func selectToolboxItem(id: String) {
        let items = rawSidebarSections().flatMap(\.items)
        guard let item = items.first(where: { Self.stableSidebarID(for: $0.id) == id }) else {
            if !FeatureVisibilitySupport.isPageVisible(SettingsRouter.shared.page, isAvailable: { $0.isAvailable }) {
                SettingsRouter.shared.page = .features
            }
            return
        }
        let feature: AppFeature?
        if case .feature(let f) = item.id {
            feature = f
        } else {
            feature = nil
        }
        if SettingsRouter.shared.destination != item.destination || SettingsRouter.shared.sidebarFeature != feature {
            SettingsRouter.shared.request(item.destination, sidebarFeature: feature)
        }
    }

    /// Detail-only Vorssaint settings view (zero inner sidebar) hosted inside ztat's single Unified Settings window.
    public func makeDetailOnlySettingsView() -> AnyView {
        if !FeatureVisibilitySupport.isPageVisible(SettingsRouter.shared.page, isAvailable: { $0.isAvailable }) {
            SettingsRouter.shared.page = .features
        }
        return AnyView(SettingsView(embeddedInZtat: true, hideSidebar: true))
    }

    /// Embedded Vorssaint Feature Hub & Settings view for ztat's unified Settings window
    /// (with all overlapping Monitor / FanControl / KeepAwake / Vorssaint Update sections removed).
    public func makeSettingsView() -> AnyView {
        makeDetailOnlySettingsView()
    }

    /// Internal bridge used by embedded Vorssaint views (Notch, SnippetLibrary, Toolbox panel,
    /// CommandBar, RadialMenu, Cleaner) to open ztat's unified Settings window focused on the exact tool.
    func requestOpenSettings() {
        let itemID = currentSelectedToolboxItemID()
        NotificationCenter.default.post(
            name: .ztatOpenSettings,
            object: ZtatSettingsRoute.toolbox(itemID: itemID)
        )
    }

    /// Internal bridge used by CommandBar and Toolbox shortcuts to open ztat's native App Uninstaller (`ZtatCleaner`).
    func openUninstaller(for appURL: URL, trashMove: UninstallerSupport.TrashMove? = nil) {
        // ZTAT-PATCH: Route all app uninstallation requests natively to ZtatCleaner.
        NotificationCenter.default.post(name: .ztatOpenAppUninstaller, object: appURL)
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
                        ZtatHostBridge.shared.dismissHubPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
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
                        ZtatHostBridge.shared.dismissHubPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                            ScreenRecorderService.shared.toggle()
                        }
                    }

                    ZtatActionTile(
                        symbol: "text.viewfinder",
                        title: ZtatL10n.tr("屏幕 OCR", "OCR"),
                        active: false
                    ) {
                        ensureAvailable(.screenOCR)
                        ZtatHostBridge.shared.dismissHubPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                            ScreenTextService.shared.capture()
                        }
                    }

                    ZtatActionTile(
                        symbol: "eyedropper",
                        title: ZtatL10n.tr("取色器", "Color"),
                        active: false
                    ) {
                        ensureAvailable(.colorPicker)
                        ZtatHostBridge.shared.dismissHubPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
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
                        ZtatHostBridge.shared.dismissHubPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            CleaningModeManager.shared.toggle()
                        }
                    }

                    ZtatActionTile(
                        symbol: "command",
                        title: ZtatL10n.tr("命令栏", "Cmd Bar"),
                        active: false
                    ) {
                        ensureAvailable(.commandBar)
                        ZtatHostBridge.shared.dismissHubPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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

            // 4. Standout Toggles: XDR Extra Brightness (Dynamic Island is owned natively by ZtatIsland)
            ZtatToolboxCard(title: ZtatL10n.tr("增强模式", "Enhancements")) {
                VStack(spacing: 8) {
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
                    ZtatMiniLinkButton(symbol: "trash", title: ZtatL10n.tr("应用卸载", "Uninstall")) {
                        // ZTAT-PATCH: Open native ZtatCleaner App Uninstaller directly.
                        NotificationCenter.default.post(name: .ztatOpenSettings, object: ZtatSettingsRoute.cleaner(sectionID: "apps"))
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

            ZtatToolboxCard(title: ZtatL10n.tr("剪贴板、暂存架与外设", "Clipboard, Shelf & Display")) {
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

// MARK: - Unified Permissions & Privacy Portal

private struct ZtatPermissionsPortalView: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var ztatL10n = ZtatLocalizationStore.shared
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        let _ = ztatL10n.revision
        let hub = FeatureStrings.hub(l10n.language)
        let bundlePath = Bundle.main.bundlePath
        let bundleID = Bundle.main.bundleIdentifier ?? ZtatBrand.bundleIdentifier
        let isInApplications = bundlePath.hasPrefix("/Applications/")
        let signDiag = Permissions.cachedCodeSigningDiagnostic

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(ZtatL10n.tr("权限与隐私", "Permissions & Privacy"))
                        .font(.title2.bold())
                    Text(ZtatL10n.tr(
                        "统一管理 ztat（\(bundleID)）的 macOS 系统授权。所有权限均按需请求，不会在未启用对应工具时触发弹窗。",
                        "Manage macOS privacy permissions for ztat (\(bundleID)) in one place. Permissions are requested only when you enable features that need them."
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: isInApplications ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(isInApplications ? Color.green : Color.orange)
                            Text(ZtatL10n.tr("当前运行位置：\(bundlePath)", "Running from: \(bundlePath)"))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: signDiag.isStableCertificate ? "lock.shield.fill" : "exclamationmark.shield.fill")
                                .foregroundStyle(signDiag.isStableCertificate ? Color.green : Color.orange)
                            if let auth = signDiag.authority, signDiag.isStableCertificate {
                                Text(ZtatL10n.tr(
                                    "代码签名：\(auth)（稳定证书签名，重启与版本更新可持久保留系统权限）",
                                    "Code Signature: \(auth) (Stable certificate — TCC permissions persist across restarts & updates)"
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            } else {
                                Text(ZtatL10n.tr(
                                    "代码签名：临时 Ad-hoc 签名（每次更新编译可能导致录屏权限重置，请使用 ./scripts/build.sh 证书签名）",
                                    "Code Signature: Ad-hoc (rebuilds may invalidate Screen Recording TCC; sign with a local certificate)"
                                ))
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        }
                        if !isInApplications {
                            Text(ZtatL10n.tr(
                                "建议仅从 /Applications/ztat.app 运行，避免系统隐私列表中出现多个同名 ztat 条目导致授权无效。",
                                "Run ztat from /Applications/ztat.app to avoid duplicate entries in macOS Privacy & Security."
                            ))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(ZtatL10n.tr(
                            "提示：macOS 在系统设置中开启“录屏与系统录音”后，当前运行进程需重启一次才能拿到新的系统录屏令牌。如开关已开但仍显示未授权，可先点击“重启 ztat 使权限生效”；若为旧签名残留，再点击对应权限的“重新开始”。",
                            "Note: macOS caches Screen Recording tokens per process. After enabling Screen Recording in System Settings, click “Relaunch ztat” below once; if an older signature entry is stuck, click “Start Over” on that permission."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button(ZtatL10n.tr("刷新权限状态", "Refresh Status")) {
                                permissions.refresh()
                            }
                            Button(ZtatL10n.tr("重启 ztat 使权限生效", "Relaunch ztat")) {
                                permissions.relaunchApp()
                            }
                        }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                }

                SettingsCard {
                    PermissionsPortalSections(hub: hub)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(22)
        }
        .onAppear {
            permissions.refresh()
        }
    }
}
