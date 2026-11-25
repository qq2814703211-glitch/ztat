// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// Single shared `NSPasteboard.general.changeCount` poller.
/// Replaces duplicate 0.8s polling timers across ClipboardHistoryService and URLCleanerService.
/// Automatically stops the RunLoop timer when zero listeners are registered.
@MainActor
public final class SharedPasteboardMonitor {
    public static let shared = SharedPasteboardMonitor()

    public typealias Handler = @MainActor (Int) -> Void

    private var handlers: [UUID: Handler] = [:]
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private let interval: TimeInterval = 0.75

    private init() {}

    @discardableResult
    public func subscribe(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers[id] = handler
        if timer == nil {
            lastChangeCount = NSPasteboard.general.changeCount
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.poll()
                }
            }
            t.tolerance = 0.25
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        return id
    }

    public func unsubscribe(_ id: UUID) {
        handlers.removeValue(forKey: id)
        if handlers.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    public var subscriberCount: Int {
        handlers.count
    }

    private func poll() {
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        for handler in handlers.values {
            handler(current)
        }
    }
}
