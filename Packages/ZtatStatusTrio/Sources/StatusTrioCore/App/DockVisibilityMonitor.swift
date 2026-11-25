import AppKit
import CoreFoundation
import CoreGraphics

@MainActor
protocol DockVisibilityMonitoring: AnyObject {
    var isDockVisible: Bool { get }
    var onChange: ((Bool) -> Void)? { get set }
    func start()
    func stop()
    func refresh()
}

/// Probes the Dock window's compositor state only when Dock autohide is enabled,
/// running `CGWindowListCopyWindowInfo` off the MainActor on a background utility queue.
///
/// ZTAT-PATCH: Perf 5 — skip `CGWindowListCopyWindowInfo` polling completely when
/// `com.apple.dock` `autohide == false`, and offload active window-list probes to a
/// background `.utility` queue so the MainActor never blocks on WindowServer IPC.
@MainActor
final class DockVisibilityMonitor: DockVisibilityMonitoring {
    private static let probeQueue = DispatchQueue(
        label: "dev.ztat.statusTrio.dockVisibility",
        qos: .utility
    )

    private let customProbe: (@MainActor () -> Bool)?
    private let autoHideProbe: @Sendable () -> Bool
    private let pollingInterval: TimeInterval
    private var isMonitoring = false
    private var isProbeInFlight = false
    private var pollGeneration: UInt64 = 0
    private var pollTimer: Timer?
    private var screenParametersObserver: NSObjectProtocol?

    private(set) var isDockVisible = true
    var onChange: ((Bool) -> Void)?

    init(
        probe: (@MainActor () -> Bool)? = nil,
        autoHideProbe: @escaping @Sendable () -> Bool = {
            DockVisibilityMonitor.isDockAutoHideEnabled()
        },
        pollingInterval: TimeInterval = 1
    ) {
        self.customProbe = probe
        self.autoHideProbe = autoHideProbe
        self.pollingInterval = pollingInterval
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        pollGeneration &+= 1

        if customProbe == nil {
            // Observe screen-parameter changes (macOS posts this when Dock autohide
            // toggles because visibleFrame changes) so polling activates/deactivates live.
            screenParametersObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reconcilePollingForAutoHidePreference()
                }
            }
            reconcilePollingForAutoHidePreference()
        } else {
            refresh()
            startPollTimer()
        }
    }

    func stop() {
        isMonitoring = false
        pollGeneration &+= 1
        isProbeInFlight = false
        stopPollTimer()
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        // A stopped monitor must not leave the Dock permanently considered
        // hidden. The next start performs a fresh probe immediately.
        isDockVisible = true
    }

    func refresh() {
        guard isMonitoring else { return }
        if let customProbe {
            applyVisibility(customProbe())
            return
        }
        guard autoHideProbe() else {
            stopPollTimer()
            applyVisibility(true)
            return
        }
        guard !isProbeInFlight else { return }
        isProbeInFlight = true
        let generation = pollGeneration
        Self.probeQueue.async { [weak self] in
            let nextValue = Self.liveVisibility()
            Task { @MainActor [weak self] in
                guard let self, self.isMonitoring, self.pollGeneration == generation else { return }
                self.isProbeInFlight = false
                self.applyVisibility(nextValue)
            }
        }
    }

    private func reconcilePollingForAutoHidePreference() {
        guard isMonitoring else { return }
        guard autoHideProbe() else {
            // ZTAT-PATCH: Perf 5 — Dock is pinned visible (`autohide == false`), skip all polling.
            stopPollTimer()
            isProbeInFlight = false
            applyVisibility(true)
            return
        }
        refresh()
        startPollTimer()
    }

    private func startPollTimer() {
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: pollingInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = pollingInterval / 2
        pollTimer = timer
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func applyVisibility(_ nextValue: Bool) {
        guard nextValue != isDockVisible else { return }
        isDockVisible = nextValue
        onChange?(nextValue)
    }

    nonisolated static func isDockAutoHideEnabled() -> Bool {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue("autohide" as CFString, domain)
        return (value as? Bool) ?? false
    }

    nonisolated static func liveVisibility() -> Bool {
        guard let dockPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?
            .processIdentifier
        else {
            return true
        }
        let onScreenWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        if !dockWindows(in: onScreenWindows, dockPID: dockPID).isEmpty {
            return true
        }
        // No Dock window on screen means the Dock is hidden. The full window
        // list is only needed to tell that apart from a restricted environment
        // that reports no windows at all.
        guard onScreenWindows.isEmpty else { return false }
        let allWindows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return isDockVisible(
            in: allWindows,
            onScreenWindows: onScreenWindows,
            dockPID: dockPID
        )
    }

    nonisolated static func isDockVisible(
        in allWindows: [[String: Any]],
        onScreenWindows: [[String: Any]],
        dockPID: pid_t
    ) -> Bool {
        let allDockWindows = dockWindows(in: allWindows, dockPID: dockPID)
        guard !allDockWindows.isEmpty else {
            // Window metadata can be unavailable in restricted environments.
            // Fail open so the animation is not silently disabled.
            return true
        }
        return !dockWindows(in: onScreenWindows, dockPID: dockPID).isEmpty
    }

    nonisolated private static func dockWindows(
        in windows: [[String: Any]],
        dockPID: pid_t
    ) -> [[String: Any]] {
        let dockWindowLevel = Int(CGWindowLevelForKey(.dockWindow))
        return windows.filter { window in
            let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let level = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
            return ownerPID == dockPID && level == dockWindowLevel
        }
    }
}
