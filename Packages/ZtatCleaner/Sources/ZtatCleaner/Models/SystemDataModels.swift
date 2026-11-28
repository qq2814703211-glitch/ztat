// SPDX-License-Identifier: GPL-3.0-or-later
// Clean-room data models for ztat's native System Data Unpacked inspector,
// project footprint aggregator, target-driven Space Plan, and scan history.

import Foundation
import SwiftUI
import ZtatCore

// MARK: - Categories

public enum SystemDataCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case snapshots
    case simulators
    case xcode
    case packages
    case aiModels
    case docker
    case virtualMachines
    case devTools
    case appCaches
    case logs
    case temporary
    case deviceBackups
    case sharedData
    case projects
    case systemReserved
    case largeFolders

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .snapshots: return ZtatL10n.tr("本地时间机器快照", "Local APFS Snapshots")
        case .simulators: return ZtatL10n.tr("模拟器与运行时", "Simulators & Runtimes")
        case .xcode: return ZtatL10n.tr("Xcode 编译产物", "Xcode Artifacts")
        case .packages: return ZtatL10n.tr("包管理器缓存", "Package Manager Caches")
        case .aiModels: return ZtatL10n.tr("AI 模型与权重", "AI Models & Weights")
        case .docker: return ZtatL10n.tr("Docker 容器与镜像", "Docker & Containers")
        case .virtualMachines: return ZtatL10n.tr("虚拟机镜像", "Virtual Machines")
        case .devTools: return ZtatL10n.tr("开发工具目录", "Developer Toolchains")
        case .appCaches: return ZtatL10n.tr("应用缓存与媒体", "App Caches & Media")
        case .logs: return ZtatL10n.tr("系统与应用日志", "Logs & Diagnostics")
        case .temporary: return ZtatL10n.tr("陈旧临时文件", "Stale Temporary Files")
        case .deviceBackups: return ZtatL10n.tr("iOS 设备备份", "iOS Device Backups")
        case .sharedData: return ZtatL10n.tr("共享与其他用户", "Shared & Other Users")
        case .projects: return ZtatL10n.tr("项目构建产物", "Project Build Artifacts")
        case .systemReserved: return ZtatL10n.tr("系统保留与云同步", "System Reserved & Cloud")
        case .largeFolders: return ZtatL10n.tr("其他大型数据目录", "Other Large Folders")
        }
    }

    public var symbolName: String {
        switch self {
        case .snapshots: return "clock.arrow.circlepath"
        case .simulators: return "iphone.gen3"
        case .xcode: return "hammer.fill"
        case .packages: return "shippingbox.fill"
        case .aiModels: return "cpu.fill"
        case .docker: return "cube.transparent.fill"
        case .virtualMachines: return "desktopcomputer"
        case .devTools: return "wrench.and.screwdriver.fill"
        case .appCaches: return "app.badge.fill"
        case .logs: return "doc.text.magnifyingglass"
        case .temporary: return "hourglass"
        case .deviceBackups: return "externaldrive.badge.timemachine"
        case .sharedData: return "person.2.fill"
        case .projects: return "folder.badge.gearshape"
        case .systemReserved: return "lock.shield.fill"
        case .largeFolders: return "folder.fill"
        }
    }

    public var tintColor: Color {
        switch self {
        case .snapshots: return .cyan
        case .simulators, .xcode: return .blue
        case .packages, .devTools: return .indigo
        case .aiModels: return .purple
        case .docker, .virtualMachines: return .teal
        case .appCaches: return .mint
        case .logs, .temporary: return .green
        case .deviceBackups, .sharedData: return .orange
        case .projects: return .pink
        case .systemReserved: return .secondary
        case .largeFolders: return .yellow
        }
    }
}

// MARK: - Safety & Recovery Taxonomy

public enum SystemDataSafety: String, CaseIterable, Codable, Sendable, Comparable {
    case safe
    case review
    case manual

    public var sortRank: Int {
        switch self {
        case .safe: return 0
        case .review: return 1
        case .manual: return 2
        }
    }

    public static func < (lhs: SystemDataSafety, rhs: SystemDataSafety) -> Bool {
        lhs.sortRank < rhs.sortRank
    }

    public var title: String {
        switch self {
        case .safe: return ZtatL10n.tr("安全清理", "Safe")
        case .review: return ZtatL10n.tr("建议确认", "Review")
        case .manual: return ZtatL10n.tr("仅查看/手动", "Manual")
        }
    }

    public var color: Color {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .manual: return .secondary
        }
    }
}

public enum SystemDataRecovery: String, Codable, Sendable {
    case rebuildsLocally
    case redownloads
    case disposable
    case permanent

    public var title: String {
        switch self {
        case .rebuildsLocally: return ZtatL10n.tr("本地可重建", "Rebuilds locally")
        case .redownloads: return ZtatL10n.tr("需联网重下", "Re-downloads")
        case .disposable: return ZtatL10n.tr("无需恢复", "Disposable")
        case .permanent: return ZtatL10n.tr("谨慎/难恢复", "Permanent")
        }
    }
}

// MARK: - Reclaim Actions

public enum SystemDataAction: Hashable, Sendable {
    /// Move paths into ztat's reversible timestamped Trash bundle via SafeDeletionEngine.
    case trashPaths([URL])
    /// Remove only regular files older than `days` inside `directory` (preserves live sockets/symlinks/mounts).
    case pruneOlderThan(directory: URL, days: Int)
    /// Run a verified CLI tool command (e.g. `xcrun simctl`, `ollama rm`, `docker system prune`).
    case toolCommand(executable: String, arguments: [String], displayCommand: String)
    /// Thin local APFS Time Machine snapshots by a bounded byte amount via `tmutil thinlocalsnapshots`.
    case thinSnapshots(bytes: Int64)
    /// Delete a specific Time Machine local snapshot date stamp via `tmutil deletelocalsnapshots`.
    case deleteSnapshot(dateStamp: String)
    /// Read-only visibility entry with manual guidance; never auto-deleted.
    case manual(guidance: String)

    public var isActionable: Bool {
        if case .manual = self { return false }
        return true
    }

    public var previewCommand: String {
        switch self {
        case .trashPaths(let urls):
            if urls.count == 1, let first = urls.first {
                return "Trash (reversible) → \(first.path)"
            }
            return "Trash (reversible) → \(urls.count) items"
        case .pruneOlderThan(let dir, let days):
            return "Prune regular files > \(days)d in \(dir.path)"
        case .toolCommand(_, _, let display):
            return display
        case .thinSnapshots(let bytes):
            return "tmutil thinlocalsnapshots / \(bytes) 4"
        case .deleteSnapshot(let stamp):
            return "tmutil deletelocalsnapshots \(stamp)"
        case .manual(let guidance):
            return guidance
        }
    }
}

// MARK: - Scanned Item

public struct SystemDataItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let category: SystemDataCategory
    public let title: String
    public let subtitle: String
    public let path: URL?
    public let bytes: Int64
    public let lastModified: Date?
    public let safety: SystemDataSafety
    public let recovery: SystemDataRecovery
    public let action: SystemDataAction
    public let projectRoot: URL?
    public let isStalled: Bool
    public let isCompressible: Bool
    public let detailNote: String?

    public init(
        id: String,
        category: SystemDataCategory,
        title: String,
        subtitle: String,
        path: URL? = nil,
        bytes: Int64,
        lastModified: Date? = nil,
        safety: SystemDataSafety,
        recovery: SystemDataRecovery,
        action: SystemDataAction,
        projectRoot: URL? = nil,
        isStalled: Bool = false,
        isCompressible: Bool = false,
        detailNote: String? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.bytes = bytes
        self.lastModified = lastModified
        self.safety = safety
        self.recovery = recovery
        self.action = action
        self.projectRoot = projectRoot
        self.isStalled = isStalled
        self.isCompressible = isCompressible
        self.detailNote = detailNote
    }

    public var idleDays: Int? {
        guard let lastModified else { return nil }
        return max(0, Int(Date().timeIntervalSince(lastModified) / 86_400))
    }
}

// MARK: - Volume Overview

public struct SystemDataVolumeOverview: Sendable, Equatable {
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let importantAvailableBytes: Int64
    public let purgeableBytes: Int64
    public let usedBytes: Int64

    public init(
        totalBytes: Int64,
        availableBytes: Int64,
        importantAvailableBytes: Int64
    ) {
        self.totalBytes = max(0, totalBytes)
        self.availableBytes = max(0, availableBytes)
        self.importantAvailableBytes = max(0, importantAvailableBytes)
        self.purgeableBytes = max(0, importantAvailableBytes - availableBytes)
        self.usedBytes = max(0, totalBytes - availableBytes)
    }
}

// MARK: - Project Footprint Group

public struct ProjectFootprintGroup: Identifiable, Sendable {
    public let id: String
    public let projectName: String
    public let projectRoot: URL
    public let rootExists: Bool
    public let lastSourceModified: Date?
    public let items: [SystemDataItem]

    public var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    public var idleDays: Int? {
        guard let date = lastSourceModified else { return nil }
        return max(0, Int(Date().timeIntervalSince(date) / 86_400))
    }

    public var isRecentlyActive: Bool {
        guard let days = idleDays else { return false }
        return days <= 7
    }
}

// MARK: - Target-Driven Space Plan

public struct SpacePlanProposal: Sendable, Equatable {
    public let targetBytes: Int64
    public let selectedIDs: Set<String>
    public let plannedBytes: Int64

    public var reachedTarget: Bool {
        plannedBytes >= targetBytes
    }
}

public enum SpacePlanBuilder {
    /// Selects actionable items to reach `targetBytes`:
    /// 1. `.safe` items largest first;
    /// 2. `.review` items longest-idle first (then largest).
    /// `.manual` items are never chosen. Trims overshoots in reverse priority order.
    public static func build(items: [SystemDataItem], targetBytes: Int64) -> SpacePlanProposal {
        guard targetBytes > 0 else {
            return SpacePlanProposal(targetBytes: targetBytes, selectedIDs: [], plannedBytes: 0)
        }

        let safeCandidates = items
            .filter { $0.safety == .safe && $0.action.isActionable && $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }

        let reviewCandidates = items
            .filter { $0.safety == .review && $0.action.isActionable && $0.bytes > 0 }
            .sorted { lhs, rhs in
                let lDate = lhs.lastModified ?? .distantPast
                let rDate = rhs.lastModified ?? .distantPast
                if lDate != rDate { return lDate < rDate }
                return lhs.bytes > rhs.bytes
            }

        let ordered = safeCandidates + reviewCandidates
        var chosen: [SystemDataItem] = []
        var total: Int64 = 0

        for item in ordered {
            if total >= targetBytes { break }
            chosen.append(item)
            total += item.bytes
        }

        // Prune redundant smaller/lower-priority items if we overshot targetBytes
        if total > targetBytes {
            var pruned = chosen
            for idx in stride(from: pruned.count - 1, through: 0, by: -1) {
                let candidate = pruned[idx]
                if total - candidate.bytes >= targetBytes {
                    total -= candidate.bytes
                    pruned.remove(at: idx)
                }
            }
            chosen = pruned
        }

        return SpacePlanProposal(
            targetBytes: targetBytes,
            selectedIDs: Set(chosen.map(\.id)),
            plannedBytes: total
        )
    }
}

// MARK: - Scan History Records

public struct SystemDataScanRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let totalBytes: Int64
    public let safeBytes: Int64
    public let reviewBytes: Int64
    public let manualBytes: Int64
    public let categoryBytes: [String: Int64]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        totalBytes: Int64,
        safeBytes: Int64,
        reviewBytes: Int64,
        manualBytes: Int64,
        categoryBytes: [String: Int64]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.totalBytes = totalBytes
        self.safeBytes = safeBytes
        self.reviewBytes = reviewBytes
        self.manualBytes = manualBytes
        self.categoryBytes = categoryBytes
    }
}

public struct SystemDataDeletionRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let itemID: String
    public let title: String
    public let path: String?
    public let bytesFreed: Int64

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        itemID: String,
        title: String,
        path: String?,
        bytesFreed: Int64
    ) {
        self.id = id
        self.timestamp = timestamp
        self.itemID = itemID
        self.title = title
        self.path = path
        self.bytesFreed = bytesFreed
    }
}

public struct SystemDataReturnedItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let deletedAt: Date
    public let currentBytes: Int64
    public let previouslyFreedBytes: Int64
}
