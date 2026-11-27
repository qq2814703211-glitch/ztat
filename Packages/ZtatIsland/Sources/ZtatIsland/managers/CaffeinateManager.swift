// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Bridge Dynamic Island Caffeinate controls directly to ZtatCore.ZtatPowerGuardRegistry
// so zero duplicate IOPMAssertions or idle timers exist alongside ZtatPowerGuard.

import Combine
import Defaults
import Foundation
import SwiftUI
import ZtatCore

@MainActor
final class CaffeinateManager: ObservableObject {
    static let shared = CaffeinateManager()

    @Published private(set) var isActive: Bool = false
    @Published private(set) var expiresAt: Date?
    @Published private(set) var remainingTime: TimeInterval?
    @Published private(set) var activeDuration: CaffeinateDuration?

    private var registryCancellable: AnyCancellable?

    private init() {
        syncFromRegistry(ZtatPowerGuardRegistry.shared.snapshot)
        registryCancellable = ZtatPowerGuardRegistry.shared.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.syncFromRegistry(snapshot)
            }
    }

    private func syncFromRegistry(_ snapshot: ZtatPowerGuardSnapshot) {
        isActive = snapshot.isActive
        expiresAt = snapshot.expirationDate
        remainingTime = snapshot.remainingSeconds
        if !snapshot.isActive {
            activeDuration = nil
        }
    }

    func activate(for duration: CaffeinateDuration) {
        activeDuration = duration
        ZtatPowerGuardRegistry.shared.activateForDuration(seconds: duration.seconds)
    }

    func deactivate() {
        activeDuration = nil
        ZtatPowerGuardRegistry.shared.disableAll()
    }

    func toggle() {
        if isActive {
            deactivate()
        } else {
            activate(for: Defaults[.caffeinateDefaultDuration])
        }
    }

    nonisolated static func expiry(from start: Date, duration: CaffeinateDuration) -> Date? {
        guard let seconds = duration.seconds else { return nil }
        return start.addingTimeInterval(seconds)
    }

    nonisolated static func remainingLabel(_ interval: TimeInterval) -> String {
        let total = Int(ceil(max(0, interval)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
