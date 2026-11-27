import AppKit
import SwiftUI
import ZtatCore

struct StatusPopoverView: View {
    /// Which window hosts this view. The primary window keeps the summary while
    /// a detail is shown beside it; the detail window renders only the page.
    enum Host {
        case primary
        case detail
    }

    @ObservedObject var panel: StatusPanelViewModel
    /// Observed so the Low Power Mode control appears the moment the helper is
    /// approved — reading `.isReady` off the shared manager without observing
    /// it left the control invisible until the popover was recreated.
    @ObservedObject private var helper: PrivilegedHelperManager = .shared
    let scrollTargets: PopoverScrollTargets
    /// The panel window's current height budget (#237). The content caps and
    /// scrolls itself at the same number the window uses, so the two never
    /// disagree about how tall the panel may get.
    @ObservedObject var layoutMetrics: StatusPanelLayoutMetrics
    @EnvironmentObject private var localization: Localization
    let requestWiFiNameAccess: () -> Void
    let requestBluetoothAuthorization: () -> Void
    let openBatterySettings: () -> Void
    let openAppBatterySettings: () -> Void
    let openWiFiSettings: () -> Void
    let openNetworkSettings: () -> Void
    let openSharingSettings: () -> Void
    let openLocationSettings: () -> Void
    let openBluetoothSettings: () -> Void
    let openBluetoothPermissionSettings: () -> Void
    let openSettings: () -> Void
    let openSoundSettings: () -> Void
    let openSoundInputSettings: () -> Void
    var openDisplaySettings: () -> Void = {}
    let openKeyboardSettings: () -> Void
    let quit: () -> Void
    /// The footer's Actions menu closes the panel before opening another window.
    var dismissPanel: () -> Void = {}
    /// Reject measurements from a retained tree after its hosting controller is replaced.
    var contentMeasurementID: UUID? = nil
    var host: Host = .primary
    // ZTAT-PATCH: Parameterized panel width and embedded hub body mode (omits duplicate outer scroll & footer chrome).
    var panelWidth: CGFloat = ZtatBrand.hubPanelWidth
    var isEmbeddedInHub: Bool = false

    /// Fill colour of the panel's level sliders, from General settings (#359).
    /// `.automatic` follows the label colour (white on a dark panel, black on a
    /// light one) instead of pinning a fixed value.
    private var levelSliderFillColor: Color {
        switch panel.panelLevelSliderColor {
        case .automatic:
            return .primary
        case let .custom(color):
            return IconAppearanceColorConversion.color(from: color)
        }
    }

    var body: some View {
        // ZTAT-PATCH: When embedded inside ztat's unified Hub root view, the outer host
        // provides the single StatusPanelScrollArea and unified header/settings chrome.
        if isEmbeddedInHub {
            embeddedRouteContent
                .environment(\.statusPanelManagesScrolling, true)
                .environment(\.airPodsConversationCache, panel.store.airPodsConversationCache)
                .environment(\.statusPanelVisibility, layoutMetrics.visibilityPublisher)
                .environment(\.panelCardSurfaceStyle, PanelCardSurfaceStyle.resolve(panel.effectivePanelBackgroundStyle))
                .environment(\.statusPanelDetailHost, host == .detail)
                .environment(\.statusPanelBoldTextEnabled, panel.statusPanelBoldTextEnabled)
                .environment(\.statusPanelMediumTextEnabled, panel.statusPanelMediumTextEnabled)
        } else {
            // One scroll surface for every route (#237). The area measures the page
            // at its natural height and only scrolls once the screen budget cannot
            // hold it, so a short page still hugs its content. The summary footer
            // stays outside the scroll view so it is always reachable.
            StatusPanelScrollArea(
                maximumHeight: layoutMetrics.maximumPanelHeight,
                fillsWindow: layoutMetrics.fillsWindow,
                onNaturalHeight: {
                    layoutMetrics.measure(contentHeight: $0, from: contentMeasurementID)
                }
            ) {
                routeContent
                    // Inside the panel there must be exactly one scroller. The
                    // detail pages and Bluetooth lists keep their own scroll views
                    // for other hosts, but disable them here.
                    .environment(\.statusPanelManagesScrolling, true)
                    .environment(\.airPodsConversationCache, panel.store.airPodsConversationCache)
                    .environment(\.statusPanelVisibility, layoutMetrics.visibilityPublisher)
            } footer: {
                if host == .primary, panel.isSummaryVisible {
                    pinnedFooter
                }
            }
            .environment(\.panelCardSurfaceStyle, PanelCardSurfaceStyle.resolve(panel.effectivePanelBackgroundStyle))
            .environment(\.statusPanelDetailHost, host == .detail)
            .frame(width: panelWidth)
            .environment(\.statusPanelBoldTextEnabled, panel.statusPanelBoldTextEnabled)
            .environment(\.statusPanelMediumTextEnabled, panel.statusPanelMediumTextEnabled)
        }
    }

    // ZTAT-PATCH: Embedded route content fills the 356pt Hub container cleanly without horizontal clipping.
    private var embeddedRouteContent: some View {
        Group {
            switch host {
            case .detail:
                if panel.route != .summary { pageContent }
            case .primary:
                if panel.isShowingDetailPage && panel.detailPresentation == .alongside {
                    summary
                } else {
                    pageContent
                }
            }
        }
        .padding(.top, 2)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The current route, inset for the panel's fixed width.
    ///
    /// The bottom inset is 12pt when the summary's pinned footer follows, which
    /// reproduces the old in-page `VStack` spacing before the footer's rule.
    private var routeContent: some View {
        Group {
            switch host {
            case .detail:
                if panel.route != .summary { pageContent }
            case .primary:
                if panel.isShowingDetailPage && panel.detailPresentation == .alongside {
                    summary
                } else {
                    pageContent
                }
            }
        }
        .padding(.top, host == .detail ? 8 : 14)
        .padding(.horizontal, 14)
        .padding(.bottom, routeBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch panel.route {
            case .summary:
                summary
            case .battery:
                BatteryDetailsView(
                    state: panel.batteryDetails,
                    onBack: { panel.showSummaryPage() },
                    onOpenBatterySettings: openBatterySettings,
                    onOpenAppBatterySettings: openAppBatterySettings,
                    onCopyValue: { copyValue($0) },
                    onAppear: { panel.actions.batteryDetailsAppeared() },
                    lowPowerMode: panel.store.lowPowerMode,
                    showsLowPowerControl: panel.settings.controlsLowPowerMode
                        && helper.isReady,
                    highPowerMode: panel.store.highPowerMode,
                    showsHighPowerControl: panel.settings.controlsLowPowerMode
                        && helper.isReady,
                    isConnectedToPower:
                        panel.store.popupSnapshot.battery.isConnectedToPower,
                    chargeToFullNow: panel.chargeToFullNowPresentation,
                    onChargeToFullNow: { panel.actions.requestChargeToFullNow() }
                )
            case .wifi:
                WiFiNetworkListView(
                    state: panel.wifiDetails,
                    onBack: { panel.showSummaryPage() },
                    onRequestNameAccess: requestWiFiNameAccess,
                    onOpenWiFiSettings: openWiFiSettings,
                    onOpenLocationSettings: openLocationSettings,
                    onSetPower: { panel.actions.setWiFiPower($0) },
                    wifiPowerRequiresConfirmation: WiFiPowerTogglePolicy.requiresConfirmation(
                        for: panel.store.popupSnapshot.wifi.state,
                        confirmsPowerOff: panel.settings.confirmsWiFiPowerOff
                    ),
                    onRefresh: { panel.actions.refreshWiFi() },
                    onOpenSharingSettings: openSharingSettings,
                    onCopyValue: { copyValue($0) },
                    showsDetails: panel.wifiDisclosure.showsDetails,
                    showsMore: panel.wifiDisclosure.showsMore,
                    onSetShowsDetails: { panel.setWiFiShowsDetails($0) },
                    onSetShowsMore: { panel.setWiFiShowsMore($0) }
                )
            case .ethernet:
                EthernetLinkView(
                    state: panel.wiredDetails,
                    onBack: { panel.showSummaryPage() },
                    onOpenNetworkSettings: openNetworkSettings,
                    onOpenSharingSettings: openSharingSettings,
                    onCopyValue: { copyValue($0) }
                )
            case .inputSource:
                InputSourceListView(
                    state: panel.inputSource,
                    onBack: { panel.showSummaryPage() },
                    onSelect: { panel.actions.selectInputSource($0) },
                    onOpenKeyboardSettings: openKeyboardSettings
                )
            case let .hardwareDetail(kind):
                HardwareDetailView(kind: kind,
                                   hardware: panel.hardwareMonitor,
                                   onBack: { panel.showSummaryPage() },
                                   metricColors: panel.hardwareMonitorMetricColors,
                                   diskRingColor: panel.hardwareDiskRingColor,
                                   topApps: panel.showsHardwareTopApps ? panel.topApps : nil,
                                   downloadCapMbps: panel.settings.hardwareDownloadCapMbps,
                                   uploadCapMbps: panel.settings.hardwareUploadCapMbps,
                                   networkChartFixedScale: panel.settings.hardwareNetworkChartFixedScale,
                                   historyWindowSeconds: panel.settings.hardwareHistoryWindowSeconds)
                    // Key the detail page by its kind. The detail window is a
                    // long-lived host that only swaps `kind` when the user picks
                    // another metric card in alongside mode, so without a fresh
                    // identity SwiftUI reuses the previous page's
                    // `HardwareDetailHistoryStore` (its points, provider and
                    // series count), painting the other metric's values onto the
                    // new 0–100% axis. A distinct id forces a clean rebuild.
                    .id(kind)
        }
    }

    /// The gap between the route content and the pinned footer. The summary
    /// keeps 12pt so the footer's rule sits where the old in-page spacing put
    /// it; an empty summary lets the footer own the whole inset.
    private var routeBottomPadding: CGFloat {
        guard host == .primary, panel.isSummaryVisible else { return 14 }
        return displayedSections.isEmpty ? 0 : 12
    }

    private var summary: some View {
        let sections = displayedSections
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(sections) { section in
                popupSection(section)

                if section != sections.last {
                    Divider()
                }
            }

            if isEmbeddedInHub {
                Divider().opacity(0.45)
                HStack(spacing: 8) {
                    Button {
                        ZtatHostBridge.shared.openSettings(route: .statusTrio(sectionID: "popover"))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 10.5, weight: .medium))
                            Text(ZtatL10n.tr("自定义状态卡片…", "Customize Cards…"))
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 4)

                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "switch.2")
                                .font(.system(size: 10.5, weight: .medium))
                            Text(ZtatL10n.tr("控制中心设置", "Control Center"))
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        // The volume device list is summary-only: keep its lifecycle tied to
        // this page so leaving for a detail route stops it, while scrolling a
        // long summary does not.
        .task(id: [
            panel.listeningModeTaskID,
            String(panel.visiblePopupSections.contains(.bluetooth)),
            String(panel.visiblePopupSections.contains(.volume))
        ]) {
            if panel.store.isPopoverVisible,
               panel.visiblePopupSections.contains(.bluetooth) || panel.visiblePopupSections.contains(.volume) {
                panel.actions.volumeListChanged()
            } else {
                panel.actions.volumeListDisappeared()
            }
        }
        .onDisappear { panel.actions.volumeListDisappeared() }
    }

    /// The summary sections actually rendered: the brightness section is
    /// dropped when every display is hidden, so no empty section or dangling
    /// separator is left behind (#241).
    private var displayedSections: [PopupSection] {
        // ZTAT-PATCH: Restore .quickActions (backed directly by ZtatPowerGuardRegistry in ztat).
        panel.displayedSummarySections
    }

    /// The footer only renders on the summary route, so its rule follows the
    /// sections that are actually drawn. When every section is hidden the rule
    /// would otherwise sit over an empty page.
    private var showsFooterRule: Bool {
        !displayedSections.isEmpty
    }

    /// The summary footer, pinned to the panel's bottom edge (#237).
    private var pinnedFooter: some View {
        VStack(spacing: 12) {
            if showsFooterRule {
                Divider()
                    .opacity(0.6)
                    .padding(.vertical, 2)
            }

            PopoverFooterView(openSettings: openSettings, quit: quit, dismissPanel: dismissPanel)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func popupSection(_ section: PopupSection) -> some View {
        switch section {
        case .battery:
            BatteryStatusView(
                state: panel.battery,
                cautionColor: .yellow,
                onOpenBatteryDetails: { panel.showBatteryPage() },
                onOpenBatterySettings: openBatterySettings,
                lowPowerMode: panel.store.lowPowerMode,
                showsLowPowerToggle: panel.settings.controlsLowPowerMode
                    && helper.isReady,
                highPowerMode: panel.store.highPowerMode,
                isConnectedToPower:
                    panel.store.popupSnapshot.battery.isConnectedToPower,
                chargeToFullNow: panel.summaryChargeToFullNowPresentation,
                onChargeToFullNow: {
                    panel.actions.requestChargeToFullNow()
                }
            )
        case .quickActions:
            if isEmbeddedInHub {
                ZtatEmbeddedPowerGuardQuickActionsView()
            } else {
                QuickActionsCardView(
                    control: panel.store.sleepControl,
                    showsDisplay: panel.settings.showsKeepScreenButton,
                    showsLid: panel.settings.showsLidSleepButton
                )
            }
        case .network:
            WiFiPowerSummaryView(panel: panel,
                state: panel.network,
                onOpenWiFiDetails: { panel.showWiFiPage(showsDetailsInitially: $0) },
                onOpenWiredDetails: { panel.showWiredPage() },
                onRequestNameAccess: requestWiFiNameAccess,
                onOpenWiFiSettings: openWiFiSettings,
                onOpenNetworkSettings: openNetworkSettings,
                onOpenLocationSettings: openLocationSettings
            )
        case .vpn:
            VPNStatusView(state: panel.vpn) { enabled in
                panel.actions.setVPNPower(enabled)
            }
        case .bluetooth:
            BluetoothStatusView(
                controller: panel.store.bluetoothDevices,
                radioPower: panel.store.bluetoothPower,
                mobileBatteryController: panel.store.mobileBattery,
                showsBatteryLevels: panel.settings.showsBluetoothBatteryLevels,
                showsAppleDevicesAndBattery: panel.settings.showsAppleDevicesAndBattery,
                nearbyBLESelections: panel.settings.nearbyBLESelections,
                trustedAppleDeviceMetadata: panel.settings.trustedAppleDeviceMetadata,
                currentTrustedAppleCandidates: panel.store.trustedAppleDeviceCandidates,
                appleDeviceLastSuccessfulIDs: panel.store.appleDeviceLastSuccessfulIDs,
                trustedDiscoveryGeneration: panel.store.trustedAppleDeviceDiscoveryGeneration,
                listOptions: panel.settings.bluetoothDeviceListOptions,
                showsRadioPowerControl: panel.settings.showsBluetoothPowerControl,
                showsBluetoothInStatusPanel: panel.settings.enabledPopupSections.contains(.bluetooth),
                listeningModePresentations: panel.settings.showsBluetoothListeningMode
                    ? panel.store.bluetoothListeningModes.huaweiBluetoothRowPresentations
                    : [:],
                onSelectListeningMode: { panel.actions.setListeningMode(address: $0, mode: $1) },
                onRequestAuthorization: requestBluetoothAuthorization,
                onOpenBluetoothSettings: openBluetoothSettings,
                onOpenBluetoothPermissionSettings: openBluetoothPermissionSettings,
                onSetRadioPower: { enabled in
                    panel.actions.setBluetoothPower(enabled)
                },
                layoutSnapshots: panel.layoutSnapshots
            )
        case .volume:
            VolumeControlsSection(
                model: panel.volumeControl,
                actions: panel.actions,
                scrollTargets: scrollTargets,
                onOpenSoundSettings: openSoundSettings,
                fillColor: levelSliderFillColor,
                matchesBrightnessThickness: panel.panelLevelSliderMatchesBrightnessThickness
            )
        case .brightness:
            BrightnessControlsView(
                state: panel.brightness,
                actions: panel.actions,
                scrollTargets: scrollTargets,
                onOpenDisplaySettings: openDisplaySettings,
                fillColor: levelSliderFillColor
            )
        case .audioInput:
            AudioInputControlsView(
                state: panel.audioInput,
                actions: panel.actions,
                scrollTargets: scrollTargets,
                onOpenSoundSettings: openSoundInputSettings,
                fillColor: levelSliderFillColor,
                matchesBrightnessThickness: panel.panelLevelSliderMatchesBrightnessThickness
            )
        case .inputSource:
            InputSourceStatusView(
                state: panel.inputSource,
                onOpen: { panel.showInputSourcePage() },
                onOpenKeyboardSettings: openKeyboardSettings
            )
        case .hardwareMonitor:
            // Fixed compact summary: the existing four rings plus one aligned
            // four-column data row. Card metric order/colour settings still feed
            // the ring colours; the summary no longer depends on card metrics.
            HardwareMonitorSummaryView(model: panel.hardwareMonitor,
                                       metricColors: panel.hardwareMonitorMetricColors,
                                       diskColor: panel.hardwareDiskRingColor,
                                       showsRings: panel.showsHardwareRings,
                                       showsSummaryRow: panel.showsHardwareSummaryRow,
                                       onOpenHardwareDetail: { panel.showHardwareDetail($0) },
                                       ringSlots: HardwareRingSlot.allCases.filter {
                                           panel.enabledHardwareRingSlots.contains($0)
                                       },
                                       memoryRingDisplayMode: panel.memoryRingDisplayMode,
                                       ssdRingDisplayMode: panel.ssdRingDisplayMode,
                                       ssdIncludeExternalInPercent: panel.hardwareSSDIncludeExternalInPercent,
                                       ssdSelectedExternalPaths: panel.hardwareSSDExternalVolumePaths,
                                       cpuRingCenterContent: panel.cpuRingCenterContent,
                                       gpuRingCenterContent: panel.gpuRingCenterContent,
                                       hardwareTemperatureMonitoringEnabled: panel.hardwareTemperatureMonitoringEnabled,
                                       hardwareRingSplitGapProgress: panel.hardwareRingSplitGapProgress,
                                       summaryMetrics: panel.enabledHardwareSummaryMetrics)
        }
    }

    private func copyValue(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// ZTAT-PATCH: Compact Quick Actions row inside the Status tab, wired directly to ZtatPowerGuardRegistry
/// so Idle Keep-Awake, Clamshell Lock, and 0% Blackout stay 100% synchronized with the Guard tab & Dynamic Island.
private struct ZtatEmbeddedPowerGuardQuickActionsView: View {
    @ObservedObject private var registry = ZtatPowerGuardRegistry.shared
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    var body: some View {
        let _ = l10n.revision
        let snap = registry.snapshot
        HStack(spacing: 6) {
            quickPill(
                symbol: snap.isIdleKeepAwakeActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                title: ZtatL10n.tr("防休眠", "Awake"),
                active: snap.isIdleKeepAwakeActive,
                tint: .green
            ) {
                registry.toggleIdleKeepAwake()
            }

            quickPill(
                symbol: snap.isClamshellLocked ? "lock.laptopcomputer" : "laptopcomputer",
                title: ZtatL10n.tr("合盖锁", "Clamshell"),
                active: snap.isClamshellLocked,
                tint: .orange
            ) {
                registry.toggleClamshellLock()
            }

            quickPill(
                symbol: snap.isBlackoutActive ? "moon.fill" : "display",
                title: ZtatL10n.tr("熄屏 0%", "Blackout"),
                active: snap.isBlackoutActive,
                tint: .indigo
            ) {
                registry.toggleBlackoutMode()
            }
        }
    }

    private func quickPill(
        symbol: String,
        title: String,
        active: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? tint : .primary.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? tint.opacity(0.16) : Color.primary.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? tint.opacity(0.35) : Color.clear, lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct WiFiPowerSummaryView: View {
    @ObservedObject var panel: StatusPanelViewModel
    @ObservedObject private var store: SystemStatusStore
    let state: PanelSummaryState
    let onOpenWiFiDetails: (Bool) -> Void
    let onOpenWiredDetails: () -> Void
    let onRequestNameAccess: () -> Void
    let onOpenWiFiSettings: () -> Void
    let onOpenNetworkSettings: () -> Void
    let onOpenLocationSettings: () -> Void

    init(panel: StatusPanelViewModel, state: PanelSummaryState, onOpenWiFiDetails: @escaping (Bool) -> Void, onOpenWiredDetails: @escaping () -> Void, onRequestNameAccess: @escaping () -> Void, onOpenWiFiSettings: @escaping () -> Void, onOpenNetworkSettings: @escaping () -> Void, onOpenLocationSettings: @escaping () -> Void) {
        self.panel = panel
        self.store = panel.store
        self.state = state
        self.onOpenWiFiDetails = onOpenWiFiDetails
        self.onOpenWiredDetails = onOpenWiredDetails
        self.onRequestNameAccess = onRequestNameAccess
        self.onOpenWiFiSettings = onOpenWiFiSettings
        self.onOpenNetworkSettings = onOpenNetworkSettings
        self.onOpenLocationSettings = onOpenLocationSettings
    }

    var body: some View {
        NetworkStatusView(
            showsWiFiPowerControl: WiFiPowerControlVisibility.showsSummaryToggle(
                state: store.popupSnapshot.wifi.state,
                isEnabled: panel.settings.showsWiFiPowerControl
            ),
            wifiPowerIsOn: WiFiPowerControlVisibility.isRadioOn(state: store.popupSnapshot.wifi.state),
            wifiPowerCanSet: !store.wifiPowerIsChanging,
            wifiPowerRequiresConfirmation: WiFiPowerTogglePolicy.requiresConfirmation(
                for: store.popupSnapshot.wifi.state,
                confirmsPowerOff: panel.settings.confirmsWiFiPowerOff
            ),
            wifiPowerFailed: store.wifiPowerFailed,
            onSetWiFiPower: { store.setWiFiPower($0) },
            state: state, onOpenWiFiDetails: onOpenWiFiDetails, onOpenWiredDetails: onOpenWiredDetails,
            onRequestNameAccess: onRequestNameAccess, onOpenWiFiSettings: onOpenWiFiSettings,
            onOpenNetworkSettings: onOpenNetworkSettings, onOpenLocationSettings: onOpenLocationSettings
        )
    }
}
