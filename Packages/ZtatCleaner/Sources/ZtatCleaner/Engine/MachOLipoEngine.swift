// SPDX-License-Identifier: GPL-3.0-or-later
// Pure-Swift Mach-O Universal Binary (FAT 32-bit & 64-bit) inspector and reversible slice slimmer,
// plus App Localization (.lproj) scanner and pruner — zero dependency on Xcode's `lipo` tool.
//
// Safety model:
// - The host CPU is detected at runtime (`hw.optional.arm64`), so a Rosetta-translated ztat still
//   keeps arm64 code on Apple Silicon.
// - Every slice of the host CPU type is kept (arm64 *and* arm64e); only foreign CPU types are dropped.
// - Each original binary is moved into a `~/.Trash/<App>_LipoBackup_<timestamp>/` bundle that is
//   recorded in Delete History, so "Restore" swaps the untouched original back in place.
// - Apple (`com.apple.*`), SIP-protected, `SafePathGuard`-rejected and ztat-owned bundles are refused.
// - Thinning / language pruning modifies sealed bundle contents, so the app's code-signature seal
//   may become invalid; this is surfaced via `codeSignatureNotice`.

import AppKit
import Darwin
import Foundation
import MachO
import ZtatCore

public struct LipoThinResult: Sendable {
    public let appName: String
    public let thinnedBinaryCount: Int
    public let reclaimedBytes: Int64
    public let languagesPrunedBytes: Int64
    public let failedCount: Int
    public let errorMessage: String?
    /// Non-nil when the bundle was modified, meaning its code-signature seal may no longer be valid.
    public var codeSignatureWarning: String? = nil
}

public final class MachOLipoEngine: @unchecked Sendable {
    public static let shared = MachOLipoEngine()

    private init() {}

    // Mach-O magic constants
    private static let fatMagic32: UInt32 = 0xcafebabe
    private static let fatCigam32: UInt32 = 0xbebafeca
    private static let fatMagic64: UInt32 = 0xcafebabf
    private static let fatCigam64: UInt32 = 0xbfbafeca
    private static let mhMagic64: UInt32 = 0xfeedfacf
    private static let mhCigam64: UInt32 = 0xcffaedfe
    private static let mhMagic32: UInt32 = 0xfeedface
    private static let mhCigam32: UInt32 = 0xcefaedfe

    private static let cpuTypeARM64: UInt32 = 0x0100000c
    private static let cpuTypeX86_64: UInt32 = 0x01000007

    /// CPU type of the physical machine, detected at runtime. `hw.optional.arm64` reports 1 on
    /// Apple Silicon even when this process runs translated under Rosetta 2.
    static let hostCPUType: UInt32 = {
        if sysctlInt32("hw.optional.arm64") == 1 || sysctlInt32("sysctl.proc_translated") == 1 {
            return cpuTypeARM64
        }
        return cpuTypeX86_64
    }()

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// Shown whenever a bundle was modified by thinning or language pruning.
    public static var codeSignatureNotice: String {
        ZtatL10n.tr(
            "瘦身修改了应用包内容，其代码签名封印可能失效（Gatekeeper、钥匙串或隐私权限可能受影响）。原始文件已存入废纸篓，可在「清理历史」中还原；清空废纸篓后瘦身将无法撤销。",
            "Thinning modified the app bundle, so its code-signature seal may no longer be valid (Gatekeeper, Keychain or privacy permissions may be affected). Originals were kept in the Trash and can be restored from Delete History; emptying the Trash makes thinning permanent."
        )
    }

    public struct FatSliceInfo: Sendable {
        public let cpuType: UInt32
        public let cpuSubtype: UInt32
        public let offset: UInt64
        public let size: UInt64
        /// Slice alignment as a power of two (from `fat_arch.align`).
        public let align: UInt32
    }

    // MARK: - Single Binary Architecture Inspection

    public static func inspectBinaryArchitecture(at url: URL) -> AppArchitecture {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? fh.close() }
        guard let header = try? fh.read(upToCount: 16), header.count >= 8 else { return .unknown }

        let magicLE = readUInt32LE(header, at: 0)
        let magicBE = readUInt32BE(header, at: 0)

        if magicBE == fatMagic32 || magicBE == fatMagic64 || magicLE == fatMagic32 || magicLE == fatMagic64 {
            let slices = parseFatSlices(at: url)
            let hasARM = slices.contains { $0.cpuType == cpuTypeARM64 }
            let hasX86 = slices.contains { $0.cpuType == cpuTypeX86_64 }
            if hasARM && hasX86 { return .universal }
            if hasARM { return .arm64 }
            if hasX86 { return .x86_64 }
            return .unknown
        }

        if magicLE == mhMagic64 || magicLE == mhMagic32 {
            let cpu = readUInt32LE(header, at: 4)
            if cpu == cpuTypeARM64 { return .arm64 }
            if cpu == cpuTypeX86_64 { return .x86_64 }
        } else if magicBE == mhMagic64 || magicBE == mhMagic32 {
            let cpu = readUInt32BE(header, at: 4)
            if cpu == cpuTypeARM64 { return .arm64 }
            if cpu == cpuTypeX86_64 { return .x86_64 }
        }
        return .unknown
    }

    /// Parses both 32-bit (`FAT_MAGIC`) and 64-bit (`FAT_MAGIC_64`) Mach-O universal binary headers.
    public static func parseFatSlices(at url: URL) -> [FatSliceInfo] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 8), head.count == 8 else { return [] }

        let magic = readUInt32BE(head, at: 0)
        let is64: Bool
        if magic == fatMagic32 {
            is64 = false
        } else if magic == fatMagic64 {
            is64 = true
        } else {
            return []
        }

        let archCount = Int(readUInt32BE(head, at: 4))
        // Sanity check: valid Mach-O FAT binaries never exceed 32 architecture slices
        // (and distinguishes Java .class files which also start with 0xCAFEBABE!)
        guard archCount >= 2 && archCount <= 32 else { return [] }

        let entrySize = is64 ? 32 : 20
        guard let table = try? fh.read(upToCount: archCount * entrySize),
              table.count == archCount * entrySize else {
            return []
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        var slices: [FatSliceInfo] = []
        slices.reserveCapacity(archCount)

        for i in 0..<archCount {
            let base = i * entrySize
            let cpuType = readUInt32BE(table, at: base)
            let cpuSubtype = readUInt32BE(table, at: base + 4)
            let offset: UInt64
            let size: UInt64
            let align: UInt32
            if is64 {
                offset = readUInt64BE(table, at: base + 8)
                size = readUInt64BE(table, at: base + 16)
                align = readUInt32BE(table, at: base + 24)
            } else {
                offset = UInt64(readUInt32BE(table, at: base + 8))
                size = UInt64(readUInt32BE(table, at: base + 12))
                align = readUInt32BE(table, at: base + 16)
            }
            guard size > 0, offset + size <= fileSize else {
                // Reject corrupt headers or non-Mach-O Java class files
                return []
            }
            slices.append(FatSliceInfo(cpuType: cpuType, cpuSubtype: cpuSubtype, offset: offset, size: size, align: align))
        }
        return slices
    }

    // MARK: - Eligibility

    /// Returns a user-facing reason when `app` must never be thinned, or nil when it is eligible.
    public static func thinningRejectionReason(for app: InstalledAppEntry) -> String? {
        let bundleURLs = [app.url.standardizedFileURL, app.actualBundleURL.standardizedFileURL]
        for url in bundleURLs {
            let resolved = url.resolvingSymlinksInPath().path
            if url.path.hasPrefix("/System/") || resolved.hasPrefix("/System/") || isSIPRestricted(url) {
                return ZtatL10n.tr("该应用受 macOS SIP 保护，已跳过", "Skipped: SIP protected bundle")
            }
        }
        var identifiers = [app.bundleIdentifier]
        if let plistID = Bundle(url: app.actualBundleURL)?.bundleIdentifier {
            identifiers.append(plistID)
        }
        for identifier in identifiers where !identifier.isEmpty {
            if SafePathGuard.isAppleBundleIdentifier(identifier) {
                return ZtatL10n.tr("Apple 系统应用不支持瘦身，已跳过", "Skipped: Apple apps are never thinned")
            }
            if SafePathGuard.isZtatBundleIdentifier(identifier) {
                return ZtatL10n.tr("禁止修改 ztat 本体", "Skipped: ztat cannot modify itself")
            }
        }
        for url in bundleURLs {
            if let reason = SafePathGuard.rejectionReason(for: url) {
                return reason
            }
        }
        return nil
    }

    // MARK: - App Bundle Dry-Run Savings Analysis

    public func analyzeApp(_ app: InstalledAppEntry) async -> LipoAppAnalysis {
        await Task.detached(priority: .utility) {
            let isSIP = app.url.path.hasPrefix("/System/") || Self.isSIPRestricted(app.actualBundleURL)
            let rejection = Self.thinningRejectionReason(for: app)
            let hostCPU = Self.hostCPUType
            var fatCount = 0
            var reclaimable: Int64 = 0

            if rejection == nil {
                for (url, slices) in self.findUniversalBinaries(in: app.actualBundleURL, hostCPU: hostCPU) {
                    let keptSize = slices.filter { $0.cpuType == hostCPU }.reduce(Int64(0)) { $0 + Int64($1.size) }
                    let currentSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    let diff = currentSize - keptSize
                    if diff > 0 {
                        fatCount += 1
                        reclaimable += diff
                    }
                }
            }

            let note: String?
            if let rejection {
                note = rejection
            } else if app.isAppStore {
                note = ZtatL10n.tr(
                    "Mac App Store 签名应用，瘦身会使代码签名封印失效",
                    "App Store bundle; thinning invalidates its code-signature seal"
                )
            } else {
                note = nil
            }

            return LipoAppAnalysis(
                id: app.id,
                app: app,
                fatBinaryCount: fatCount,
                reclaimableBytes: reclaimable,
                isSIPProtected: isSIP,
                isAppStoreSealed: app.isAppStore,
                detailNote: note
            )
        }.value
    }

    // MARK: - Thinning

    private struct ThinPassOutcome: Sendable {
        var count = 0
        var saved: Int64 = 0
        var failed = 0
        var lastError: String?
        var backupFolder: URL?
        var backups: [TrashedFilePair] = []
    }

    /// Keeps every host-CPU slice of all Mach-O FAT binaries in `app`, moving each original into a
    /// Delete-History-tracked Trash bundle first so the operation is fully reversible.
    public func thinApp(
        _ app: InstalledAppEntry,
        alsoPruneLanguages: Bool,
        keepLanguageCodes: [String],
        onLog: (@Sendable (String, Bool) -> Void)? = nil
    ) async -> LipoThinResult {
        if let reason = Self.thinningRejectionReason(for: app) {
            onLog?("Skipped \(app.name): \(reason)", true)
            return Self.failure(app, reason)
        }

        // The app must be fully quit before its binaries are replaced
        if !app.bundleIdentifier.isEmpty,
           let stillRunning = await SafeDeletionEngine.terminateAndWait(bundleIdentifier: app.bundleIdentifier) {
            let reason = SafeDeletionEngine.appStillRunningMessage(stillRunning)
            onLog?(reason, true)
            return Self.failure(app, reason)
        }

        await MainActor.run {
            TrashSentinelMonitor.shared.suspendForInternalOperation()
        }
        defer {
            Task { @MainActor in
                TrashSentinelMonitor.shared.resumeAfterInternalOperation()
            }
        }

        let hostCPU = Self.hostCPUType
        let thinOutcome: ThinPassOutcome = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var outcome = ThinPassOutcome()
            let binaries = self.findUniversalBinaries(in: app.actualBundleURL, hostCPU: hostCPU)
            guard !binaries.isEmpty else { return outcome }

            let backupFolder = SafeDeletionEngine.shared.newTrashBundleURL(label: "\(app.name)_LipoBackup")
            do {
                try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            } catch {
                outcome.failed = binaries.count
                outcome.lastError = ZtatL10n.tr(
                    "无法在废纸篓中创建备份目录：\(error.localizedDescription)",
                    "Could not create the Trash backup folder: \(error.localizedDescription)"
                )
                return outcome
            }
            outcome.backupFolder = backupFolder

            for (binaryURL, slices) in binaries {
                let keep = slices.filter { $0.cpuType == hostCPU }
                guard !keep.isEmpty, keep.count < slices.count else { continue }
                do {
                    guard let result = try self.thinBinaryReversibly(binaryURL, keeping: keep, backupFolder: backupFolder) else {
                        continue
                    }
                    outcome.backups.append(TrashedFilePair(
                        originalPath: binaryURL.path,
                        trashedPath: result.backupURL.path,
                        sizeBytes: result.originalSize
                    ))
                    outcome.count += 1
                    outcome.saved += result.saved
                    onLog?("Thinned \(binaryURL.lastPathComponent): -\(CleanerFormatters.bytes(result.saved))", false)
                } catch {
                    outcome.failed += 1
                    outcome.lastError = error.localizedDescription
                    onLog?("Thin failed for \(binaryURL.lastPathComponent): \(error.localizedDescription)", true)
                }
            }

            if outcome.backups.isEmpty {
                SafeDeletionEngine.removeDirectoryIfEmpty(backupFolder)
            }
            // Touch bundle modification date so Finder refreshes reported size
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: app.url.path)
            return outcome
        }.value

        if let backupFolder = thinOutcome.backupFolder, !thinOutcome.backups.isEmpty {
            await SafeDeletionEngine.shared.recordHistory(
                title: "\(app.name) — Lipo",
                sourceModule: SafeDeletionEngine.lipoBackupSourceModule,
                bundleFolder: backupFolder,
                files: thinOutcome.backups,
                totalBytes: thinOutcome.saved,
                playSound: false
            )
        }

        var langSaved: Int64 = 0
        if alsoPruneLanguages {
            let langs = await scanLanguages(in: app, keepLanguageCodes: keepLanguageCodes)
            let toRemove = langs.filter { !$0.isPreferred }.flatMap(\.urls)
            if !toRemove.isEmpty {
                let res = await SafeDeletionEngine.shared.trashItems(
                    urls: toRemove,
                    bundleLabel: "\(app.name)_Languages",
                    sourceModule: "lipo",
                    onLog: onLog
                )
                langSaved = res.freedBytes
            }
        }

        let totalDelta = thinOutcome.saved + langSaved
        if totalDelta > 0 {
            await MainActor.run {
                CleanerSettingsStore.shared.addLipoSavedBytes(totalDelta)
            }
        }

        let modifiedBundle = thinOutcome.count > 0 || langSaved > 0
        if modifiedBundle {
            onLog?(Self.codeSignatureNotice, true)
        }

        return LipoThinResult(
            appName: app.name,
            thinnedBinaryCount: thinOutcome.count,
            reclaimedBytes: thinOutcome.saved,
            languagesPrunedBytes: langSaved,
            failedCount: thinOutcome.failed,
            errorMessage: thinOutcome.lastError,
            codeSignatureWarning: modifiedBundle ? Self.codeSignatureNotice : nil
        )
    }

    private static func failure(_ app: InstalledAppEntry, _ reason: String) -> LipoThinResult {
        LipoThinResult(
            appName: app.name,
            thinnedBinaryCount: 0,
            reclaimedBytes: 0,
            languagesPrunedBytes: 0,
            failedCount: 1,
            errorMessage: reason
        )
    }

    /// FAT binaries that contain at least one host-CPU slice *and* at least one foreign slice.
    private func findUniversalBinaries(in bundleURL: URL, hostCPU: UInt32) -> [(URL, [FatSliceInfo])] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var results: [(URL, [FatSliceInfo])] = []
        let skipExts: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "svg", "icns", "pdf", "tiff", "car",
            "plist", "strings", "json", "xml", "html", "css", "js", "ts", "txt", "md",
            "nib", "storyboardc", "momd", "ttf", "otf", "woff", "woff2", "mp3", "wav",
            "aiff", "m4a", "mp4", "mov", "zip", "gz", "tar", "db", "sqlite", "lproj"
        ]

        while let obj = enumerator.nextObject() {
            autoreleasepool {
                guard let url = obj as? URL else { return }
                let ext = url.pathExtension.lowercased()
                if skipExts.contains(ext) { return }
                guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                      vals.isRegularFile == true,
                      vals.isSymbolicLink != true,
                      (vals.fileSize ?? 0) >= 4096 else {
                    return
                }
                let slices = Self.parseFatSlices(at: url)
                if slices.count >= 2,
                   slices.contains(where: { $0.cpuType == hostCPU }),
                   slices.contains(where: { $0.cpuType != hostCPU }) {
                    results.append((url, slices))
                }
            }
        }
        return results
    }

    /// Writes a thinned copy next to `binaryURL`, moves the original into `backupFolder` (in the Trash),
    /// then installs the thinned copy. On any failure the original is put back. Returns nil when
    /// thinning would not shrink the file.
    private func thinBinaryReversibly(
        _ binaryURL: URL,
        keeping keep: [FatSliceInfo],
        backupFolder: URL
    ) throws -> (backupURL: URL, originalSize: Int64, saved: Int64)? {
        let fm = FileManager.default
        let origAttrs = try fm.attributesOfItem(atPath: binaryURL.path)
        let origSize = (origAttrs[.size] as? NSNumber)?.int64Value ?? 0
        let perms = origAttrs[.posixPermissions] as? NSNumber

        let tempURL = binaryURL.deletingLastPathComponent()
            .appendingPathComponent(".\(binaryURL.lastPathComponent).ztat-lipo-\(UUID().uuidString.prefix(8))")
        defer {
            if fm.fileExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }
        }

        let newSize = try writeThinnedBinary(from: binaryURL, keeping: keep, to: tempURL)
        guard newSize > 0, newSize < origSize else { return nil }
        if let perms {
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tempURL.path)
        }

        // Preserve the untouched original in the Trash bundle before anything is replaced.
        let backupURL = SafeDeletionEngine.shared.uniqueDestination(in: backupFolder, preferredName: binaryURL.lastPathComponent)
        try fm.moveItem(at: binaryURL, to: backupURL)
        do {
            try fm.moveItem(at: tempURL, to: binaryURL)
        } catch {
            // Never leave the app without its binary: put the original back.
            try? fm.moveItem(at: backupURL, to: binaryURL)
            throw error
        }
        return (backupURL, origSize, origSize - newSize)
    }

    /// Writes `keep` (all host-CPU slices) to `dest`: a plain Mach-O when one slice remains, otherwise a
    /// new FAT container preserving each slice's cputype/cpusubtype and alignment. Returns the byte size.
    private func writeThinnedBinary(from source: URL, keeping keep: [FatSliceInfo], to dest: URL) throws -> Int64 {
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
            throw Self.lipoError(ZtatL10n.tr("无法创建临时文件", "Could not create temporary file"))
        }
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: dest)
        defer { try? writer.close() }

        let ordered = keep.sorted { $0.offset < $1.offset }
        if ordered.count == 1 {
            try copyRange(reader, offset: ordered[0].offset, length: ordered[0].size, to: writer)
        } else {
            func layout(entrySize: Int) -> (placements: [(FatSliceInfo, UInt64)], end: UInt64) {
                var cursor = UInt64(8 + ordered.count * entrySize)
                var placements: [(FatSliceInfo, UInt64)] = []
                for slice in ordered {
                    let alignment = UInt64(1) << UInt64(min(slice.align, 16))
                    cursor = (cursor + alignment - 1) / alignment * alignment
                    placements.append((slice, cursor))
                    cursor += slice.size
                }
                return (placements, cursor)
            }
            var plan = layout(entrySize: 20)
            let needs64 = plan.end > UInt64(UInt32.max)
            if needs64 {
                plan = layout(entrySize: 32)
            }

            var header = Data()
            header.appendBigEndian(needs64 ? Self.fatMagic64 : Self.fatMagic32)
            header.appendBigEndian(UInt32(ordered.count))
            for (slice, newOffset) in plan.placements {
                header.appendBigEndian(slice.cpuType)
                header.appendBigEndian(slice.cpuSubtype)
                if needs64 {
                    header.appendBigEndian(newOffset)
                    header.appendBigEndian(slice.size)
                    header.appendBigEndian(min(slice.align, 16))
                    header.appendBigEndian(UInt32(0))
                } else {
                    header.appendBigEndian(UInt32(newOffset))
                    header.appendBigEndian(UInt32(slice.size))
                    header.appendBigEndian(min(slice.align, 16))
                }
            }
            try writer.write(contentsOf: header)
            var written = UInt64(header.count)
            for (slice, newOffset) in plan.placements {
                if newOffset > written {
                    try writer.write(contentsOf: Data(count: Int(newOffset - written)))
                }
                try copyRange(reader, offset: slice.offset, length: slice.size, to: writer)
                written = newOffset + slice.size
            }
        }
        try writer.synchronize()
        return Int64(try writer.offset())
    }

    private func copyRange(_ reader: FileHandle, offset: UInt64, length: UInt64, to writer: FileHandle) throws {
        try reader.seek(toOffset: offset)
        var remaining = length
        let chunkSize: UInt64 = 1 << 20
        while remaining > 0 {
            try autoreleasepool {
                let want = Int(min(remaining, chunkSize))
                guard let chunk = try reader.read(upToCount: want), !chunk.isEmpty else {
                    throw Self.lipoError("Unexpected EOF reading Mach-O slice")
                }
                try writer.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        }
    }

    private static func lipoError(_ message: String) -> NSError {
        NSError(domain: "ztat.lipo", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func isSIPRestricted(_ url: URL) -> Bool {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return false }
        return (st.st_flags & UInt32(SF_RESTRICTED)) != 0
    }

    // MARK: - App Localization (.lproj) Scanner

    public func scanLanguages(in app: InstalledAppEntry, keepLanguageCodes: [String]) async -> [LanguageBundleItem] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let keepNormalized = Set(keepLanguageCodes.map { CleanerSettingsStore.normalizeLanguageCode($0).lowercased() } + ["base", "en"])
            let searchRoots = [
                app.actualBundleURL.appendingPathComponent("Contents/Resources"),
                app.actualBundleURL.appendingPathComponent("Contents/PlugIns"),
                app.actualBundleURL.appendingPathComponent("Contents/Frameworks")
            ]

            var grouped: [String: [URL]] = [:]
            for root in searchRoots where fm.fileExists(atPath: root.path) {
                if let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in true }
                ) {
                    while let item = enumerator.nextObject() as? URL {
                        if item.pathExtension.lowercased() == "lproj" {
                            enumerator.skipDescendants()
                            let code = item.deletingPathExtension().lastPathComponent
                            if code.lowercased() == "base" { continue }
                            grouped[code, default: []].append(item)
                        }
                    }
                }
            }

            let locale = Locale.current
            var items: [LanguageBundleItem] = []
            for (code, urls) in grouped {
                let norm = CleanerSettingsStore.normalizeLanguageCode(code).lowercased()
                let isPreferred = keepNormalized.contains(norm) || keepNormalized.contains(code.lowercased())
                let totalSize = urls.reduce(Int64(0)) { $0 + SafeDeletionEngine.logicalSize(of: $1) }
                let display = locale.localizedString(forIdentifier: code) ?? code
                items.append(LanguageBundleItem(
                    id: code,
                    code: code,
                    displayName: "\(display) (\(code))",
                    urls: urls,
                    totalSize: totalSize,
                    isPreferred: isPreferred,
                    isSelectedForRemoval: !isPreferred
                ))
            }
            return items.sorted { lhs, rhs in
                if lhs.isPreferred != rhs.isPreferred { return lhs.isPreferred }
                return lhs.totalSize > rhs.totalSize
            }
        }.value
    }

    // MARK: - Endian Helpers

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
        | (UInt32(data[offset + 1]) << 16)
        | (UInt32(data[offset + 2]) << 8)
        | UInt32(data[offset + 3])
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        (UInt64(readUInt32BE(data, at: offset)) << 32)
        | UInt64(readUInt32BE(data, at: offset + 4))
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
