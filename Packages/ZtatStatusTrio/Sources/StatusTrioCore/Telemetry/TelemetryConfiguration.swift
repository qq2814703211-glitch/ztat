import Foundation

struct TelemetryConfiguration: Sendable {
    // ZTAT-PATCH: Removed upstream telemetry endpoint; telemetry is permanently disabled in ztat.
    static let productionEndpoint = URL(string: "about:blank")!
    static let appID = "status-trio"
    static let schemaVersion = 1
    static let successMinimumInterval: TimeInterval = 20 * 60 * 60
    static let failureCooldown: TimeInterval = 6 * 60 * 60
    static let reporterCheckInterval: TimeInterval = 6 * 60 * 60
    static let requestTimeout: TimeInterval = 2.5
    let endpoint: URL
    let appID: String
    let schemaVersion: Int
    let successMinimumInterval: TimeInterval
    let failureCooldown: TimeInterval
    let reporterCheckInterval: TimeInterval
    let requestTimeout: TimeInterval

    init(endpoint: URL = productionEndpoint, appID: String = Self.appID,
         schemaVersion: Int = Self.schemaVersion,
         successMinimumInterval: TimeInterval = Self.successMinimumInterval,
         failureCooldown: TimeInterval = Self.failureCooldown,
         reporterCheckInterval: TimeInterval = Self.reporterCheckInterval,
         requestTimeout: TimeInterval = Self.requestTimeout) {
        self.endpoint = endpoint
        self.appID = appID
        self.schemaVersion = schemaVersion
        self.successMinimumInterval = successMinimumInterval
        self.failureCooldown = failureCooldown
        self.reporterCheckInterval = reporterCheckInterval
        self.requestTimeout = requestTimeout
    }
}
