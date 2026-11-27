// ZTAT-PATCH: Public host bridge integrating Status Trio as ztat's primary menu bar icon and unified Liquid Glass Hub panel host.

import AppKit
import Combine
import SwiftUI
import ZtatCore

@MainActor
public protocol ZtatHubPanelContentProviding: AnyObject {
    func makeHubRootView(statusTrioBody: AnyView) -> AnyView
    func makeExtraContextMenuItems() -> [NSMenuItem]
    func openUnifiedSettings()
    func hubPanelVisibilityDidChange(isVisible: Bool)
}

/// Public sidebar item descriptor for flattening Status categories directly into ztat's single Unified Settings sidebar.
public struct ZtatStatusTrioSectionItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let symbolName: String

    public init(id: String, title: String, symbolName: String) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
    }
}

@MainActor
public final class ZtatStatusTrioHost {
    public static let shared = ZtatStatusTrioHost()

    private var environment: AppEnvironment?
    private weak var hubContentProvider: (any ZtatHubPanelContentProviding)?
    private var languageObserver: NSObjectProtocol?

    private init() {}

    /// Starts the status monitor graph, adaptive 3-slot icon controller, and
    /// primary Liquid Glass `AnchoredStatusPanel` hosting `hubContentProvider`.
    public func start(hubContentProvider: (any ZtatHubPanelContentProviding)?) {
        if environment != nil {
            stop()
        }

        // One-time upgrade for existing ztat users who inherited the old sparse 3-card default
        // ([.battery, .network, .volume]) so they get rich cards & Power Modes out of the box.
        Self.migrateLegacySparseDefaultsIfNeeded()

        self.hubContentProvider = hubContentProvider
        let environment = AppEnvironment.live(
            hubContentProvider: hubContentProvider,
            panelWidth: ZtatBrand.hubPanelWidth,
            isEmbeddedHost: true
        )
        self.environment = environment
        syncLocalizationFromUnifiedStore()
        languageObserver = NotificationCenter.default.addObserver(
            forName: .ztatLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncLocalizationFromUnifiedStore()
            }
        }
        environment.start()
    }

    public func stop() {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        guard let environment else { return }
        environment.statusBarController.dismissPopover()
        environment.statusBarController.setVisible(false)
        environment.stop()
        self.environment = nil
        self.hubContentProvider = nil
    }

    public var keepsPanelOpenWhenOpeningSettings: Bool {
        environment?.settings.keepsPanelOpenWhenOpeningSettings ?? false
    }

    public func primaryStatusItemFrame() -> NSRect? {
        environment?.statusBarController.statusItemScreenFrame()
    }

    public func setSettingsVisible(_ visible: Bool) {
        environment?.setEmbeddedSettingsVisible(visible)
    }

    public func activeHubTabDidChange(_ tab: ZtatHubTab) {
        environment?.statusBarController.setActiveHubTab(tab)
    }

    public func toggleHubPanel() {
        environment?.statusBarController.openPopoverFromShortcut()
    }

    public func showHubPanel() {
        environment?.statusBarController.showPopover()
    }

    public func dismissHubPanel() {
        environment?.statusBarController.dismissPopover()
    }

    public func settingsSectionItems() -> [ZtatStatusTrioSectionItem] {
        let localization = environment?.localization ?? Localization.shared
        let ordered: [(SettingsView.Section, String)] = [
            (.appIcon, "macwindow.on.rectangle"),
            (.battery, "battery.100percent"),
            (.network, "wifi"),
            (.bluetooth, "dot.radiowaves.left.and.right"),
            (.audio, "speaker.wave.3.fill"),
            (.brightness, "sun.max.fill"),
            (.monitor, "gauge.with.dots.needle.bottom.50percent"),
            (.popover, "list.bullet.rectangle"),
            (.general, "slider.horizontal.3"),
        ]
        return ordered.map { section, symbol in
            ZtatStatusTrioSectionItem(
                id: section.rawValue,
                title: section.title(localization),
                symbolName: symbol
            )
        }
    }

    public func makeSettingsDetailView(sectionID: String) -> AnyView {
        guard let environment else {
            return AnyView(EmptyView())
        }
        let section = SettingsView.Section(rawValue: sectionID) ?? .appIcon
        return AnyView(
            LocalizedRootView(localization: environment.localization) {
                SettingsView(
                    store: environment.settings,
                    statusStore: environment.store,
                    localization: environment.localization,
                    inputSourceController: environment.inputSourceController,
                    globalShortcutController: environment.globalShortcutController,
                    chargeToFullNow: environment.chargeToFullNow,
                    onShowIconGuide: { [weak environment] in
                        environment?.onboardingWindowController.show()
                    },
                    isEmbeddedInUnifiedSettings: true,
                    externalSection: section
                )
                .environmentObject(environment.chargingEffectClock)
            }
        )
    }

    public func makeSettingsView() -> AnyView {
        makeSettingsDetailView(sectionID: SettingsView.Section.appIcon.rawValue)
    }

    private func syncLocalizationFromUnifiedStore() {
        guard let localization = environment?.localization else { return }
        let pref = ZtatLocalizationStore.shared.preference
        if let code = pref.statusLanguageCode, let lang = AppLanguage(rawValue: code) {
            localization.setPreference(.language(lang))
        } else {
            localization.setPreference(.system)
        }
    }

    private static func migrateLegacySparseDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "ztat.status.migratedRichDefaults.v1"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)

        // Enable Power Modes by default if never explicitly disabled by the user after migration
        if defaults.object(forKey: SettingsStore.controlsLowPowerModeDefaultsKey) == nil {
            defaults.set(true, forKey: SettingsStore.controlsLowPowerModeDefaultsKey)
        }

        // If the user previously had only the old sparse 3-card default, expand to the rich default set
        if let stored = defaults.array(forKey: SettingsStore.enabledPopupSectionsDefaultsKey) as? [String] {
            let storedSet = Set(stored)
            if storedSet == Set(["battery", "network", "volume"]) {
                let expanded = SettingsStore.defaultEnabledPopupSections.map(\.rawValue)
                defaults.set(expanded, forKey: SettingsStore.enabledPopupSectionsDefaultsKey)
            }
        }
    }
}
