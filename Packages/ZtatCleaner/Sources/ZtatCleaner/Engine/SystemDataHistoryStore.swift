// SPDX-License-Identifier: GPL-3.0-or-later
// Lightweight local JSON persistence for System Data scan trends and
// "returned after deletion" cache tracking.

import Foundation

public struct SystemDataHistorySnapshot: Codable, Sendable {
    public var scans: [SystemDataScanRecord]
    public var deletions: [SystemDataDeletionRecord]

    public init(scans: [SystemDataScanRecord] = [], deletions: [SystemDataDeletionRecord] = []) {
        self.scans = scans
        self.deletions = deletions
    }
}

public final class SystemDataHistoryStore: @unchecked Sendable {
    public static let shared = SystemDataHistoryStore()

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "dev.ztat.app.cleaner.sysdata.history.io", qos: .utility)
    private let fileURL: URL
    private let maxScans = 60
    private let maxDeletions = 200
    private var snapshot: SystemDataHistorySnapshot
    private var isLoaded = false

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support/ztat")
            self.fileURL = URL(fileURLWithPath: appSupport, isDirectory: true)
                .appendingPathComponent("cleaner_sysdata_history.json")
        }
        self.snapshot = SystemDataHistorySnapshot()
    }

    private func ensureLoadedLocked() {
        guard !isLoaded else { return }
        isLoaded = true
        self.snapshot = Self.load(from: self.fileURL)
    }

    public func currentSnapshot() -> SystemDataHistorySnapshot {
        lock.lock()
        ensureLoadedLocked()
        let copy = snapshot
        lock.unlock()
        return copy
    }

    public func recordScan(_ record: SystemDataScanRecord) {
        lock.lock()
        ensureLoadedLocked()
        snapshot.scans.append(record)
        if snapshot.scans.count > maxScans {
            snapshot.scans.removeFirst(snapshot.scans.count - maxScans)
        }
        let copy = snapshot
        lock.unlock()
        enqueueSave(copy)
    }

    public func recordDeletions(_ records: [SystemDataDeletionRecord]) {
        guard !records.isEmpty else { return }
        lock.lock()
        ensureLoadedLocked()
        snapshot.deletions.append(contentsOf: records)
        if snapshot.deletions.count > maxDeletions {
            snapshot.deletions.removeFirst(snapshot.deletions.count - maxDeletions)
        }
        let copy = snapshot
        lock.unlock()
        enqueueSave(copy)
    }

    public func clearAll() {
        lock.lock()
        isLoaded = true
        snapshot = SystemDataHistorySnapshot()
        lock.unlock()
        let targetURL = self.fileURL
        ioQueue.async {
            try? FileManager.default.removeItem(at: targetURL)
        }
    }

    /// Compares `currentTotal` against the earliest scan within the last 7 days (or previous scan).
    public func weekOverWeekDelta(currentTotal: Int64) -> Int64? {
        let scans = currentSnapshot().scans
        guard scans.count >= 2 else { return nil }
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        if let baseline = scans.first(where: { $0.timestamp >= weekAgo }) {
            return currentTotal - baseline.totalBytes
        }
        return currentTotal - scans[scans.count - 2].totalBytes
    }

    /// Detects items that were previously reclaimed and have re-accumulated >= 10 MB.
    public func detectReturnedItems(currentItems: [SystemDataItem], minBytes: Int64 = 10 * 1_048_576) -> [SystemDataReturnedItem] {
        let deletions = currentSnapshot().deletions
        guard !deletions.isEmpty else { return [] }

        var latestDeletionByKey: [String: SystemDataDeletionRecord] = [:]
        for del in deletions {
            let key = del.path?.lowercased() ?? del.itemID.lowercased()
            if let existing = latestDeletionByKey[key] {
                if del.timestamp > existing.timestamp {
                    latestDeletionByKey[key] = del
                }
            } else {
                latestDeletionByKey[key] = del
            }
        }

        var returned: [SystemDataReturnedItem] = []
        for item in currentItems where item.bytes >= minBytes {
            let key = item.path?.standardizedFileURL.path.lowercased() ?? item.id.lowercased()
            if let del = latestDeletionByKey[key] {
                returned.append(SystemDataReturnedItem(
                    id: item.id,
                    title: item.title,
                    deletedAt: del.timestamp,
                    currentBytes: item.bytes,
                    previouslyFreedBytes: del.bytesFreed
                ))
            }
        }
        return returned.sorted { $0.currentBytes > $1.currentBytes }
    }

    private static func load(from url: URL) -> SystemDataHistorySnapshot {
        guard let data = try? Data(contentsOf: url) else {
            return SystemDataHistorySnapshot()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SystemDataHistorySnapshot.self, from: data)) ?? SystemDataHistorySnapshot()
    }

    private func enqueueSave(_ value: SystemDataHistorySnapshot) {
        let targetURL = self.fileURL
        ioQueue.async {
            let dir = targetURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(value) else { return }
            try? data.write(to: targetURL, options: [.atomic])
        }
    }
}
