// SPDX-License-Identifier: GPL-3.0-or-later
// In-process Trash Sentinel (`FSEventStream` on `~/.Trash`) — strict zero-idle when disabled,
// zero separate LaunchAgent daemon required, anti-reentrancy pause/resume during internal moves,
// self-app & Trash-bundle exclusion, and debounced routing to ztat's native App Uninstaller.

import AppKit
import CoreServices
import Foundation
import ZtatCore

@MainActor
public final class TrashSentinelMonitor: ObservableObject {
    public static let shared = TrashSentinelMonitor()

    @Published public private(set) var isRunning: Bool = false

    private var stream: FSEventStreamRef?
    private let watcherQueue = DispatchQueue(label: "dev.ztat.cleaner.sentinel", qos: .utility)
    private var internalSuspendDepth: Int = 0
    private var recentlyPromptedPaths: [String: Date] = [:]

    private init() {}

    public func syncWithSettings() {
        let enabled = CleanerSettingsStore.shared.sentinelEnabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    public func suspendForInternalOperation() {
        internalSuspendDepth += 1
    }

    public func resumeAfterInternalOperation() {
        // Brief grace window so asynchronous FSEvents from our own Trash move drain cleanly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.internalSuspendDepth = max(0, self.internalSuspendDepth - 1)
        }
    }

    public func start() {
        guard stream == nil else { return }
        let trashPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        let paths = [trashPath] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
        )

        let callback: FSEventStreamCallback = { _, _, numEvents, eventPaths, _, _ in
            guard let cfArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String],
                  cfArray.count == numEvents else { return }
            for rawPath in cfArray {
                Task { @MainActor in
                    TrashSentinelMonitor.shared.handleTrashEventPath(rawPath)
                }
            }
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            nil,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else {
            ZtatLog.cleaner.error("Failed to create Trash Sentinel FSEventStream.")
            return
        }

        FSEventStreamSetDispatchQueue(created, watcherQueue)
        if FSEventStreamStart(created) {
            stream = created
            isRunning = true
            ZtatLog.cleaner.info("Trash Sentinel started watching ~/.Trash.")
        } else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
        }
    }

    public func stop() {
        guard let existing = stream else {
            isRunning = false
            return
        }
        FSEventStreamStop(existing)
        FSEventStreamInvalidate(existing)
        FSEventStreamRelease(existing)
        stream = nil
        isRunning = false
        ZtatLog.cleaner.info("Trash Sentinel stopped.")
    }

    private func handleTrashEventPath(_ rawPath: String) {
        guard internalSuspendDepth == 0 else { return }
        let fm = FileManager.default
        let trashRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").standardizedFileURL.path
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL

        // Must be a top-level `.app` directly placed in `~/.Trash/` (not inside one of our own undo bundles)
        guard url.pathExtension.lowercased() == "app" else { return }
        guard url.deletingLastPathComponent().path == trashRoot else { return }
        guard fm.fileExists(atPath: url.path) else { return }

        // Ignore ztat itself
        let lowerName = url.lastPathComponent.lowercased()
        if lowerName == "ztat.app" || lowerName == "ztat-dev.app" { return }
        if let bid = Bundle(url: url)?.bundleIdentifier,
           (bid == ZtatBrand.bundleIdentifier || bid == ZtatBrand.devBundleIdentifier) {
            return
        }

        // Debounce duplicate FSEvents within 5 seconds
        let now = Date()
        recentlyPromptedPaths = recentlyPromptedPaths.filter { now.timeIntervalSince($0.value) < 5.0 }
        if recentlyPromptedPaths[url.path] != nil { return }
        recentlyPromptedPaths[url.path] = now

        ZtatLog.cleaner.info("Trash Sentinel detected trashed app: \(url.lastPathComponent, privacy: .public)")
        NotificationCenter.default.post(name: .ztatOpenAppUninstaller, object: url)
    }
}
