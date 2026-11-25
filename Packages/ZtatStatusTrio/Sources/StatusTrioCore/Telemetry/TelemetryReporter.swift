import AppKit
import Combine
import Foundation

@MainActor
final class TelemetryReporter {
    private let settings: SettingsStore
    private let localization: Localization
    private let client: any TelemetrySending
    private let isEligible: Bool
    private let configuration: TelemetryConfiguration
    private let wakeNotificationCenter: NotificationCenter
    private let sleep: @Sendable (Duration) async throws -> Void
    private let snapshotContext: @MainActor (AppLanguage, AppIconPlacement) -> TelemetryContext?

    private var consent: TelemetryConsent
    private var isStarted = false
    private var consentCancellable: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?
    private var periodicTask: Task<Void, Never>?
    private var periodicTaskID: UUID?
    private var attemptTask: Task<Void, Never>?
    private var attemptTaskID: UUID?

    init(
        settings: SettingsStore,
        localization: Localization,
        client: any TelemetrySending,
        eligibilityContext: TelemetryEligibilityContext,
        configuration: TelemetryConfiguration,
        wakeNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            // A multi-hour check interval gains nothing from precision; a wide
            // tolerance lets the system coalesce the wake.
            try await Task.sleep(for: duration, tolerance: duration / 5)
        },
        snapshotContext: @escaping @MainActor (AppLanguage, AppIconPlacement) -> TelemetryContext?
    ) {
        self.settings = settings
        self.localization = localization
        self.client = client
        isEligible = TelemetryEligibility.isEligible(eligibilityContext)
        self.configuration = configuration
        self.wakeNotificationCenter = wakeNotificationCenter
        self.sleep = sleep
        self.snapshotContext = snapshotContext
        consent = settings.telemetryConsentSnapshot
    }

    func start() {
        // ZTAT-PATCH: Upstream telemetry permanently disabled in ztat; zero observers, tasks, or network traffic.
        isStarted = false
    }

    func stop() {
        isStarted = false
    }

    /// Schedules a best-effort send while keeping the task owned by this reporter.
    func sendIfNeeded() {
        // ZTAT-PATCH: Telemetry no-op.
    }

    private func receiveConsent(_ updatedConsent: TelemetryConsent) {
        let wasEnabled = consent.canShareAnonymousAnalytics
        consent = updatedConsent
        if wasEnabled, !consent.canShareAnonymousAnalytics {
            // A withdrawal is not a scheduling question: stop the work and drop
            // the identifier even in a build that would never send.
            cancelAttempt()
            cancelPeriodicChecks()
            discardStoredIdentity()
            return
        }
        guard isStarted, isEligible else { return }
        if !consent.canShareAnonymousAnalytics {
            cancelAttempt()
            cancelPeriodicChecks()
            return
        }
        guard !wasEnabled else { return }
        startPeriodicChecks()
        sendIfNeeded()
    }

    private func startPeriodicChecks() {
        guard isStarted,
              isEligible,
              consent.canShareAnonymousAnalytics,
              periodicTask == nil else { return }

        let taskID = UUID()
        periodicTaskID = taskID
        let interval = Duration.milliseconds(
            Int(configuration.reporterCheckInterval * 1_000)
        )
        let sleepOperation = sleep
        periodicTask = Task { @MainActor [weak self, sleepOperation] in
            defer { self?.finishPeriodicChecks(id: taskID) }
            while !Task.isCancelled {
                do {
                    try await sleepOperation(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.sendIfNeeded()
            }
        }
    }

    private func discardStoredIdentity() {
        let client = self.client
        Task { await client.discardStoredIdentity() }
    }

    private func cancelAttempt() {
        attemptTask?.cancel()
        attemptTask = nil
        attemptTaskID = nil
    }

    private func cancelPeriodicChecks() {
        periodicTask?.cancel()
        periodicTask = nil
        periodicTaskID = nil
    }

    private func finishAttempt(id: UUID) {
        guard attemptTaskID == id else { return }
        attemptTask = nil
        attemptTaskID = nil
    }

    private func finishPeriodicChecks(id: UUID) {
        guard periodicTaskID == id else { return }
        periodicTask = nil
        periodicTaskID = nil
    }
}

@MainActor
protocol TelemetryReporting: AnyObject {
    func start()
    func stop()
}

extension TelemetryReporter: TelemetryReporting {}
