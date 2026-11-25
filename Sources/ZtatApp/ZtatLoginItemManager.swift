// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ServiceManagement

/// Manages macOS Login Item registration for ztat using ServiceManagement (macOS 14+).
@MainActor
final class ZtatLoginItemManager: ObservableObject {
    static let shared = ZtatLoginItemManager()

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var statusDescription: String = ""

    private init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = (status == .enabled)
        switch status {
        case .enabled:
            statusDescription = "Enabled"
        case .requiresApproval:
            statusDescription = "Requires approval in System Settings → Login Items"
        case .notRegistered, .notFound:
            statusDescription = "Disabled"
        @unknown default:
            statusDescription = "Unknown"
        }
    }

    func setEnabled(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Gracefully handle dev/unbundled runs where SMAppService cannot register
        }
        refresh()
    }
}
