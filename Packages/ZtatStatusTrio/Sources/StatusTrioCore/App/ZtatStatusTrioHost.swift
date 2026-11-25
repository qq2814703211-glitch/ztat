// ZTAT-PATCH: Public host bridge integrating Status Trio as ztat's primary menu bar icon and unified Liquid Glass Hub panel host.

import AppKit
import SwiftUI
import ZtatCore

@MainActor
public protocol ZtatHubPanelContentProviding: AnyObject {
    func makeHubRootView(statusTrioBody: AnyView) -> AnyView
    func makeExtraContextMenuItems() -> [NSMenuItem]
    func openUnifiedSettings()
    func hubPanelVisibilityDidChange(isVisible: Bool)
}

@MainActor
public final class ZtatStatusTrioHost {
    public static let shared = ZtatStatusTrioHost()

    private var environment: AppEnvironment?
    private weak var hubContentProvider: (any ZtatHubPanelContentProviding)?

    private init() {}

    /// Starts Status Trio's full monitor graph, adaptive 3-slot icon controller, and
    /// primary Liquid Glass `AnchoredStatusPanel` hosting `hubContentProvider`.
    ///
    /// Deliberately skips `SingleInstanceGuard`, `NSApp.setActivationPolicy`, Sparkle,
    /// telemetry, and standalone Settings/Onboarding windows (all owned by `ZtatAppDelegate`).
    public func start(hubContentProvider: (any ZtatHubPanelContentProviding)?) {
        if environment != nil {
            stop()
        }

        // Enable macOS 26+ native Liquid Glass card surfaces inside the unified Hub panel.
        UserDefaults.standard.register(defaults: [PanelCardSurfaceExperiment.defaultsKey: true])

        self.hubContentProvider = hubContentProvider
        let environment = AppEnvironment.live(
            hubContentProvider: hubContentProvider,
            panelWidth: ZtatBrand.hubPanelWidth,
            isEmbeddedHost: true
        )
        self.environment = environment
        environment.start()
    }

    public func stop() {
        guard let environment else { return }
        environment.statusBarController.dismissPopover()
        environment.statusBarController.setVisible(false)
        environment.stop()
        self.environment = nil
        self.hubContentProvider = nil
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

    public func makeSettingsView() -> AnyView {
        guard let environment else {
            return AnyView(EmptyView())
        }
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
                    isEmbeddedInUnifiedSettings: true
                )
                .environmentObject(environment.chargingEffectClock)
            }
        )
    }
}
