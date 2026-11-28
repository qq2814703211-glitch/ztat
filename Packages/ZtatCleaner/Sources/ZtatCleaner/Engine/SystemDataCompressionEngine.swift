// SPDX-License-Identifier: GPL-3.0-or-later
// Clean-room APFS transparent folder compression using macOS `ditto --hfsCompression`
// with SafePathGuard, hard-link / already-compressed checks, free-space margin, and atomic swap.

import Darwin
import Foundation
import ZtatCore

public struct FolderCompressionResult: Sendable {
    public let succeeded: Bool
    public let originalBytes: Int64
    public let compressedBytes: Int64
    public let savedBytes: Int64
    public let message: String
}

public enum SystemDataCompressionEngine {
    /// Transparently compresses a directory in place using APFS/HFS+ compression (`ditto --hfsCompression`).
    /// Files remain readable seamlessly by macOS and every app without manual decompression.
    public static func compressDirectory(at url: URL) async -> FolderCompressionResult {
        let cleanURL = url.standardizedFileURL

        // 1. Safety guard
        if let reason = SafePathGuard.rejectionReason(for: cleanURL) {
            return FolderCompressionResult(succeeded: false, originalBytes: 0, compressedBytes: 0, savedBytes: 0, message: reason)
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: cleanURL.path, isDirectory: &isDir), isDir.boolValue else {
            return FolderCompressionResult(
                succeeded: false, originalBytes: 0, compressedBytes: 0, savedBytes: 0,
                message: ZtatL10n.tr("目标不是有效目录。", "Target is not a valid directory.")
            )
        }
        if (try? fm.destinationOfSymbolicLink(atPath: cleanURL.path)) != nil {
            return FolderCompressionResult(
                succeeded: false, originalBytes: 0, compressedBytes: 0, savedBytes: 0,
                message: ZtatL10n.tr("不支持压缩符号链接。", "Cannot compress a symbolic link.")
            )
        }

        // 2. Measure original size & verify no hard links / not already mostly compressed / not stalled
        let preCheck = await Task.detached(priority: .utility) { () -> (bytes: Int64, newestMod: Date?, stalled: Bool, hasHardLinks: Bool, alreadyCompressed: Bool) in
            let localFM = FileManager.default
            let m = SystemDataDiskWalker.measureSync(url: cleanURL, timeoutSeconds: 20)
            if m.stalled || Task.isCancelled {
                return (m.bytes, m.newestModified, true, false, false)
            }
            let startVolume = SystemDataDiskWalker.volumeIdentifier(of: cleanURL)
            let deadline = Date().addingTimeInterval(15)
            var hasHardLinks = false
            var checkedFiles = 0
            var compressedFiles = 0
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .linkCountKey, .volumeIdentifierKey]
            if let enumerator = localFM.enumerator(at: cleanURL, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
                var ticks = 0
                while let child = enumerator.nextObject() as? URL {
                    ticks += 1
                    if ticks & 0xFF == 0 {
                        if Task.isCancelled || Date() > deadline {
                            return (m.bytes, m.newestModified, true, false, false)
                        }
                    }
                    guard let vals = try? child.resourceValues(forKeys: Set(keys)) else { continue }
                    if vals.isSymbolicLink == true {
                        if vals.isDirectory == true { enumerator.skipDescendants() }
                        continue
                    }
                    if let startVolume,
                       let childVol = vals.volumeIdentifier as? NSObject,
                       !startVolume.isEqual(childVol) {
                        if vals.isDirectory == true { enumerator.skipDescendants() }
                        continue
                    }
                    guard vals.isRegularFile == true else { continue }
                    if (vals.linkCount ?? 1) > 1 {
                        hasHardLinks = true
                        break
                    }
                    if checkedFiles < 200 {
                        var st = stat()
                        if lstat(child.path, &st) == 0 && (st.st_flags & UInt32(UF_COMPRESSED)) != 0 {
                            compressedFiles += 1
                        }
                        checkedFiles += 1
                    }
                }
            }
            let mostlyCompressed = checkedFiles >= 10 && Double(compressedFiles) / Double(checkedFiles) >= 0.85
            return (m.bytes, m.newestModified, false, hasHardLinks, mostlyCompressed)
        }.value

        if preCheck.stalled {
            return FolderCompressionResult(
                succeeded: false, originalBytes: preCheck.bytes, compressedBytes: preCheck.bytes, savedBytes: 0,
                message: ZtatL10n.tr("目录扫描超时，已取消压缩以防磁盘空间不足。", "Directory scan timed out; aborted compression to prevent disk-full risk.")
            )
        }
        guard preCheck.bytes >= 10 * 1_048_576 else {
            return FolderCompressionResult(
                succeeded: false, originalBytes: preCheck.bytes, compressedBytes: preCheck.bytes, savedBytes: 0,
                message: ZtatL10n.tr("目录体积过小，无需压缩。", "Directory is too small to benefit from compression.")
            )
        }
        if preCheck.hasHardLinks {
            return FolderCompressionResult(
                succeeded: false, originalBytes: preCheck.bytes, compressedBytes: preCheck.bytes, savedBytes: 0,
                message: ZtatL10n.tr("目录包含硬链接文件，已跳过透明压缩以防空间膨胀。", "Skipped compression: directory contains hard-linked files.")
            )
        }
        if preCheck.alreadyCompressed {
            return FolderCompressionResult(
                succeeded: false, originalBytes: preCheck.bytes, compressedBytes: preCheck.bytes, savedBytes: 0,
                message: ZtatL10n.tr("该目录已处于 APFS 透明压缩状态。", "Directory is already transparently compressed.")
            )
        }

        // 3. Free-space margin check (require originalBytes + 1 GB headroom on target volume)
        let overview = SystemDataDiskWalker.volumeOverview(at: cleanURL.deletingLastPathComponent())
        let requiredFree = preCheck.bytes + 1_073_741_824
        guard overview.availableBytes >= requiredFree else {
            return FolderCompressionResult(
                succeeded: false, originalBytes: preCheck.bytes, compressedBytes: preCheck.bytes, savedBytes: 0,
                message: ZtatL10n.tr(
                    "磁盘剩余空间不足（需至少 \(CleanerFormatters.bytes(requiredFree)) 可用空间才能安全压缩）。",
                    "Insufficient free disk space (need at least \(CleanerFormatters.bytes(requiredFree)) free to compress safely)."
                )
            )
        }

        // 4. Create sibling temp copy with `ditto --hfsCompression`
        let parentDir = cleanURL.deletingLastPathComponent()
        let tempURL = parentDir.appendingPathComponent(".\(cleanURL.lastPathComponent).ztat-compress-\(UUID().uuidString)")
        defer {
            if fm.fileExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }
        }

        guard let out = try? await CleanerProcessRunner.runAsync(
            "/usr/bin/ditto",
            ["--hfsCompression", cleanURL.path, tempURL.path],
            timeout: 180
        ), out.succeeded else {
            return FolderCompressionResult(
                succeeded: false, originalBytes: preCheck.bytes, compressedBytes: preCheck.bytes, savedBytes: 0,
                message: ZtatL10n.tr("APFS 压缩执行失败或超时，原目录保持不变。", "APFS compression failed or timed out; original directory untouched.")
            )
        }

        let afterMeasure = await SystemDataDiskWalker.measure(url: tempURL, timeoutSeconds: 20)
        let saved = max(0, preCheck.bytes - afterMeasure.bytes)
        // Require at least 8% savings to justify swapping
        if afterMeasure.stalled || afterMeasure.bytes == 0 || Double(afterMeasure.bytes) > Double(preCheck.bytes) * 0.92 {
            return FolderCompressionResult(
                succeeded: false, originalBytes: preCheck.bytes, compressedBytes: afterMeasure.bytes, savedBytes: 0,
                message: ZtatL10n.tr("压缩收益低于 8%，已保留原目录不变。", "Compression saved less than 8%; kept original directory untouched.")
            )
        }

        // 4b. TOCTOU guard: verify the original directory was NOT modified while `ditto` ran
        let recheck = await SystemDataDiskWalker.measure(url: cleanURL, timeoutSeconds: 15)
        if recheck.stalled || recheck.newestModified != preCheck.newestMod {
            return FolderCompressionResult(
                succeeded: false, originalBytes: preCheck.bytes, compressedBytes: preCheck.bytes, savedBytes: 0,
                message: ZtatL10n.tr("压缩期间原目录发生了写入变动，已放弃替换以防数据丢失。", "Directory changed during compression; aborted swap to prevent data loss.")
            )
        }

        // 5. Atomic swap via FileManager.replaceItemAt
        do {
            _ = try fm.replaceItemAt(cleanURL, withItemAt: tempURL, backupItemName: nil, options: [])
            return FolderCompressionResult(
                succeeded: true,
                originalBytes: preCheck.bytes,
                compressedBytes: afterMeasure.bytes,
                savedBytes: saved,
                message: ZtatL10n.tr(
                    "APFS 透明压缩完成：节省 \(CleanerFormatters.bytes(saved))（原 \(CleanerFormatters.bytes(preCheck.bytes)) → 现 \(CleanerFormatters.bytes(afterMeasure.bytes))）。",
                    "APFS compression complete: saved \(CleanerFormatters.bytes(saved)) (\(CleanerFormatters.bytes(preCheck.bytes)) → \(CleanerFormatters.bytes(afterMeasure.bytes)))."
                )
            )
        } catch {
            return FolderCompressionResult(
                succeeded: false,
                originalBytes: preCheck.bytes,
                compressedBytes: preCheck.bytes,
                savedBytes: 0,
                message: ZtatL10n.tr("替换压缩目录失败：\(error.localizedDescription)", "Failed to swap compressed directory: \(error.localizedDescription)")
            )
        }
    }
}
