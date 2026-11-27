// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Unified ZtatPowerGuard backend powering StatusTrio's Low Power Mode,
// High Power Mode (3-way Low/Auto/High), Auto Low Power Mode (#246), and Quick Actions
// without requiring a separate Developer-ID LaunchDaemon.

import Foundation
import PowerHelperProtocol
import ZtatCore

@MainActor
final class ZtatPowerGuardHelperService: PrivilegedHelperServicing {
    var isSupported: Bool { true }
    var status: PrivilegedHelperStatus { .enabled }

    func register() throws {}

    func unregisterForRecovery() async throws {}

    func verifyConnection() async throws {
        await ZtatPowerGuardRegistry.shared.refreshPowerModes()
    }

    func openLoginItemsSettings() {
        ZtatHostBridge.shared.openSettings(route: .powerGuard)
    }
}

final class ZtatPowerGuardLowPowerClient: LowPowerModeClienting, @unchecked Sendable {
    func readLowPowerMode() async throws -> Bool {
        await ZtatPowerGuardRegistry.shared.readLowPowerMode()
    }

    func setLowPowerMode(_ enabled: Bool) async throws -> Bool {
        let res = await ZtatPowerGuardRegistry.shared.setLowPowerMode(enabled, allowInteractivePrompt: true)
        if !res.success, let err = res.error {
            throw LowPowerModeClientError.rejected(err)
        }
        return res.observed
    }
}

final class ZtatPowerGuardHighPowerClient: HighPowerModeClienting, @unchecked Sendable {
    func protocolVersion() async throws -> Int {
        PowerHelperProtocolVersion.current
    }

    func highPowerModeSupported() async throws -> Bool {
        await ZtatPowerGuardRegistry.shared.readHighPowerModeSupport()
    }

    func readHighPowerMode() async throws -> Bool {
        await ZtatPowerGuardRegistry.shared.readHighPowerMode()
    }

    func setHighPowerMode(_ enabled: Bool) async throws -> Bool {
        let res = await ZtatPowerGuardRegistry.shared.setHighPowerMode(enabled, allowInteractivePrompt: true)
        if !res.success, let err = res.error {
            throw HighPowerModeClientError.rejected(err)
        }
        return res.observed
    }

    func canReadLowPowerMode() async -> Bool {
        true
    }
}
