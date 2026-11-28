// SPDX-License-Identifier: GPL-3.0-or-later
// Bounded-concurrency, hard-link-deduplicated, mount-boundary-safe disk walker
// with a stall watchdog so hung FUSE/SMB/Cloud mounts never freeze scans.

import Darwin
import Foundation

public struct DiskWalkMeasurement: Sendable {
    public let bytes: Int64
    public let fileCount: Int
    public let newestModified: Date?
    public let stalled: Bool

    public static let empty = DiskWalkMeasurement(bytes: 0, fileCount: 0, newestModified: nil, stalled: false)
}

public actor SystemDataWalkGate {
    private let maxConcurrent: Int
    private var active: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int = max(2, ProcessInfo.processInfo.activeProcessorCount)) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    public func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            active = max(0, active - 1)
        }
    }
}

public enum SystemDataDiskWalker {
    public static let sharedGate = SystemDataWalkGate()

    public struct InodeKey: Hashable, Sendable {
        public let device: UInt64
        public let inode: UInt64
    }

    /// Reads boot-volume total, available, and purgeable space.
    public static func volumeOverview(at url: URL = URL(fileURLWithPath: "/")) -> SystemDataVolumeOverview {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return SystemDataVolumeOverview(totalBytes: 0, availableBytes: 0, importantAvailableBytes: 0)
        }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? available
        return SystemDataVolumeOverview(
            totalBytes: total,
            availableBytes: available,
            importantAvailableBytes: important
        )
    }

    /// Silent Full Disk Access check that never prompts a TCC sheet.
    public static func hasFullDiskAccess() -> Bool {
        let safariDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Safari")
        return (try? FileManager.default.contentsOfDirectory(atPath: safariDir)) != nil
    }

    /// Checks whether `url` resides on the same filesystem volume as `/`.
    public static func isOnBootVolume(_ url: URL) -> Bool {
        guard let rootID = volumeIdentifier(of: URL(fileURLWithPath: "/")),
              let targetID = volumeIdentifier(of: url) else {
            return true
        }
        return rootID.isEqual(targetID)
    }

    public static func volumeIdentifier(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    /// Measures allocated disk bytes and newest modification date under `url`.
    /// - Deduplicates hard links (`linkCount > 1`) by `(st_dev, st_ino)` via `lstat`.
    /// - Never follows symlinks and never crosses volume mount boundaries.
    /// - Aborts cleanly if wall-clock exceeds `timeoutSeconds` (returns `stalled: true`).
    public static func measure(
        url: URL,
        timeoutSeconds: TimeInterval = 25,
        skipSubpaths: Set<String> = []
    ) async -> DiskWalkMeasurement {
        guard !Task.isCancelled else { return .empty }
        await sharedGate.acquire()
        if Task.isCancelled {
            await sharedGate.release()
            return .empty
        }
        let worker = Task.detached(priority: .utility) {
            measureSync(url: url, timeoutSeconds: timeoutSeconds, skipSubpaths: skipSubpaths)
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        await sharedGate.release()
        return result
    }

    public static func measureSync(
        url: URL,
        timeoutSeconds: TimeInterval = 25,
        skipSubpaths: Set<String> = []
    ) -> DiskWalkMeasurement {
        let fm = FileManager.default
        let cleanURL = url.standardizedFileURL
        guard fm.fileExists(atPath: cleanURL.path) else { return .empty }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .linkCountKey,
            .contentModificationDateKey,
            .volumeIdentifierKey
        ]

        // Single file or symlink fast path
        if let rootVals = try? cleanURL.resourceValues(forKeys: Set(keys)),
           rootVals.isSymbolicLink == true || rootVals.isDirectory != true {
            let bytes = Int64(rootVals.totalFileAllocatedSize ?? rootVals.fileAllocatedSize ?? rootVals.fileSize ?? 0)
            return DiskWalkMeasurement(
                bytes: bytes,
                fileCount: 1,
                newestModified: rootVals.contentModificationDate,
                stalled: false
            )
        }

        let startVolume = volumeIdentifier(of: cleanURL)
        let deadline = Date().addingTimeInterval(max(2, timeoutSeconds))
        var seenInodes = Set<InodeKey>()
        var totalBytes: Int64 = 0
        var fileCount = 0
        var newestDate: Date?
        var stalled = false

        guard let enumerator = fm.enumerator(
            at: cleanURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return .empty
        }

        var ticks = 0
        for case let child as URL in enumerator {
            ticks += 1
            if ticks & 0xFF == 0 {
                if Task.isCancelled { return .empty }
                if Date() > deadline {
                    stalled = true
                    break
                }
            }

            if !skipSubpaths.isEmpty {
                let childPath = child.standardizedFileURL.path
                if skipSubpaths.contains(childPath) {
                    enumerator.skipDescendants()
                    continue
                }
            }

            guard let vals = try? child.resourceValues(forKeys: Set(keys)) else { continue }

            // Never follow symlinks into external trees
            if vals.isSymbolicLink == true {
                if vals.isDirectory == true { enumerator.skipDescendants() }
                continue
            }

            // Never cross mount boundaries (e.g. mounted .dmg or FUSE inside a scanned tree)
            if let startVolume,
               let childVol = vals.volumeIdentifier as? NSObject,
               !startVolume.isEqual(childVol) {
                if vals.isDirectory == true { enumerator.skipDescendants() }
                continue
            }

            if let mod = vals.contentModificationDate {
                if newestDate == nil || mod > newestDate! {
                    newestDate = mod
                }
            }

            guard vals.isRegularFile == true else { continue }

            // Deduplicate hard-linked files by (st_dev, st_ino)
            if let links = vals.linkCount, links > 1 {
                if let key = inodeKey(forPath: child.path) {
                    if !seenInodes.insert(key).inserted {
                        continue
                    }
                }
            }

            let size = Int64(vals.totalFileAllocatedSize ?? vals.fileAllocatedSize ?? vals.fileSize ?? 0)
            totalBytes += max(0, size)
            fileCount += 1
        }

        return DiskWalkMeasurement(
            bytes: totalBytes,
            fileCount: fileCount,
            newestModified: newestDate,
            stalled: stalled
        )
    }

    /// Computes `(st_dev, st_ino)` via `lstat(2)` without following symlinks.
    public static func inodeKey(forPath path: String) -> InodeKey? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return InodeKey(device: UInt64(bitPattern: Int64(st.st_dev)), inode: UInt64(st.st_ino))
    }

    /// Resolves `realpath(3)` for overlap deduplication.
    public static func canonicalPath(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        if let resolved = realpath(p, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return p
    }
}
