import Foundation

protocol TelemetrySending: Sendable {
    func sendIfNeeded(context: TelemetryContext) async
    /// Forgets the stored installation identifier and the request timestamps.
    /// Called once consent is withdrawn, so nothing on disk links this install
    /// to a heartbeat it sent while consent was still granted.
    func discardStoredIdentity() async
}

actor TelemetryClient: TelemetrySending {
    static let installationIDKey = "telemetry.installationId"
    static let lastAttemptAtKey = "telemetry.lastAttemptAt"
    static let lastSuccessfulAtKey = "telemetry.lastSuccessfulAt"

    private let transport: any TelemetryTransport
    private let configuration: TelemetryConfiguration
    private let now: @Sendable () -> Date
    private let defaults: UserDefaults
    private var isSending = false

    init(
        transport: any TelemetryTransport,
        configuration: TelemetryConfiguration,
        now: @escaping @Sendable () -> Date = { Date() },
        persistenceSuiteName: String? = nil
    ) {
        self.transport = transport
        self.configuration = configuration
        self.now = now
        if let persistenceSuiteName, let suiteDefaults = UserDefaults(suiteName: persistenceSuiteName) {
            defaults = suiteDefaults
        } else {
            defaults = .standard
        }
    }

    func sendIfNeeded(context _: TelemetryContext) async {
        // ZTAT-PATCH: Upstream telemetry disabled in ztat; no-op with zero network or defaults writes.
    }

    func discardStoredIdentity() {
        defaults.removeObject(forKey: Self.installationIDKey)
        defaults.removeObject(forKey: Self.lastAttemptAtKey)
        defaults.removeObject(forKey: Self.lastSuccessfulAtKey)
    }

    private func storedDate(forKey key: String) -> Date? {
        defaults.object(forKey: key) as? Date
    }

    private func isWithinInterval(_ storedDate: Date?, interval: TimeInterval, at now: Date) -> Bool {
        guard let storedDate else { return false }
        let elapsed = now.timeIntervalSince(storedDate)
        return elapsed < interval
    }
}
