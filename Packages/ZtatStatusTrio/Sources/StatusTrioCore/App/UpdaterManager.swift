// ZTAT-PATCH: Stubbed UpdaterManager as a no-op with Sparkle completely removed.
import AppKit
import Combine
import SwiftUI

@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    var isFullScreenActive: @MainActor () -> Bool = { FullScreenActivity.isActive() }
    var directFeedURLString: () -> String? = { nil }

    var automaticallyChecksForUpdatesBinding: Binding<Bool> {
        Binding(
            get: { false },
            set: { _ in }
        )
    }

    private override init() {
        super.init()
    }

    func start(activationPolicy _: AppActivationPolicy) {}

    func checkForUpdates(preference _: UpdatePreference = .githubFirst) {}

    func currentProxiedFeedURLString() -> String? { nil }

    @discardableResult
    func advanceUpdateSource(after _: Error?) -> Bool { false }

    func restoreInitialUpdateSource() {}
}
