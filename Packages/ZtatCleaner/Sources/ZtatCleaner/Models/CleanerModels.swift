// SPDX-License-Identifier: GPL-3.0-or-later
// Clean-room macOS application uninstaller, orphan finder, Mach-O lipo slimmer,
// developer environment cleaner, PKG/plugins/services manager, and file search models.

import AppKit
import Foundation
import ZtatCore

// MARK: - Sidebar Navigation

public struct ZtatCleanerSectionItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let symbolName: String
    public let keywords: String

    public init(id: String, title: String, symbolName: String, keywords: String) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.keywords = keywords
    }
}

public enum CleanerSectionID: String, CaseIterable, Identifiable, Sendable {
    case apps
    case systemData
    case orphans
    case lipo
    case developer
    case packages
    case plugins
    case services
    case fileSearch
    case history
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .apps: return ZtatL10n.tr("应用卸载", "App Uninstaller")
        case .systemData: return ZtatL10n.tr("系统数据透视", "System Data")
        case .orphans: return ZtatL10n.tr("孤立残留", "Orphaned Files")
        case .lipo: return ZtatL10n.tr("架构瘦身", "App Lipo & Languages")
        case .developer: return ZtatL10n.tr("开发环境清理", "Developer Cleaner")
        case .packages: return ZtatL10n.tr("安装包与收据", "PKG & Receipts")
        case .plugins: return ZtatL10n.tr("系统插件", "Plugins & Extensions")
        case .services: return ZtatL10n.tr("后台服务", "Launch Services")
        case .fileSearch: return ZtatL10n.tr("深度文件搜索", "File Search")
        case .history: return ZtatL10n.tr("清理历史与还原", "Delete History")
        case .settings: return ZtatL10n.tr("清理偏好与哨兵", "Cleaner Settings")
        }
    }

    public var symbolName: String {
        switch self {
        case .apps: return "trash.square.fill"
        case .systemData: return "internaldrive.fill"
        case .orphans: return "doc.badge.ellipsis"
        case .lipo: return "scissors"
        case .developer: return "hammer.fill"
        case .packages: return "shippingbox.fill"
        case .plugins: return "puzzlepiece.extension.fill"
        case .services: return "gearshape.2.fill"
        case .fileSearch: return "magnifyingglass.circle.fill"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "slider.horizontal.3"
        }
    }

    public var searchKeywords: String {
        switch self {
        case .apps:
            return "app uninstall delete reset bundle leftover trash 应用 卸载 残留 重置 拖放"
        case .systemData:
            return "system data unpacked storage disk space snapshot tmutil simulator docker ai ollama huggingface vm backup project node_modules compression 系统数据 透视 存储 空间 快照 模拟器 项目 压缩"
        case .orphans:
            return "orphan zombie leftover library cleanup 孤立 僵尸 残留 清理"
        case .lipo:
            return "lipo universal binary arm64 x86_64 architecture slim translation language lproj 架构 瘦身 通用二进制 语言包 翻译"
        case .developer:
            return "developer xcode deriveddata cargo npm pnpm yarn pip uv conda gradle maven docker jetbrains vscode cursor zed 开发 环境 缓存"
        case .packages:
            return "pkg receipt bom pkgutil installer forget 安装包 收据"
        case .plugins:
            return "plugins audio au vst vst3 quicklook prefpane screensaver fonts spotlight widgets 插件 扩展 音频 字体"
        case .services:
            return "daemon launchagent launchdaemon launchctl xpc startup service 后台 守护进程 启动项 服务"
        case .fileSearch:
            return "file search regex tags comments size date rename 文件 搜索 正则 标签 注释"
        case .history:
            return "undo history restore trash 历史 还原 撤销 废纸篓"
        case .settings:
            return "sentinel trash watcher sensitivity exclusions folders brew zap 哨兵 废纸篓监听 灵敏度 排除 目录"
        }
    }
}

// MARK: - Search Sensitivity & Sorting

public enum CleanerSearchSensitivity: Int, CaseIterable, Identifiable, Codable, Sendable {
    case strict = 0
    case enhanced = 1
    case deep = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .strict: return ZtatL10n.tr("严格（推荐）", "Strict (Recommended)")
        case .enhanced: return ZtatL10n.tr("增强", "Enhanced")
        case .deep: return ZtatL10n.tr("深度", "Deep")
        }
    }

    public var subtitle: String {
        switch self {
        case .strict:
            return ZtatL10n.tr("仅精确匹配 Bundle ID、应用名与签名权限组，零误报优先。", "Exact bundle ID, app name, and entitlement matches only; safest default.")
        case .enhanced:
            return ZtatL10n.tr("增加版本剥离名与子串匹配，发现更多供应商相关目录。", "Adds version-stripped names and substring matching for broader discovery.")
        case .deep:
            return ZtatL10n.tr("额外纳入开发商名、Team ID 与 Spotlight 元数据，清理前请仔细核对。", "Adds vendor/team ID and Spotlight metadata matching; review selections carefully.")
        }
    }
}

public enum AppSortOrder: String, CaseIterable, Identifiable, Sendable {
    case name
    case size
    case dateAdded
    case dateModified
    case dateCreated
    case lastUsed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .name: return ZtatL10n.tr("按名称", "Name")
        case .size: return ZtatL10n.tr("按体积", "Size")
        case .dateAdded: return ZtatL10n.tr("按添加日期", "Date Added")
        case .dateModified: return ZtatL10n.tr("按修改日期", "Date Modified")
        case .dateCreated: return ZtatL10n.tr("按创建日期", "Date Created")
        case .lastUsed: return ZtatL10n.tr("按上次打开", "Last Used")
        }
    }
}

public enum FileSortOrder: String, CaseIterable, Identifiable, Sendable {
    case size
    case name
    case path

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .size: return ZtatL10n.tr("按大小", "Size")
        case .name: return ZtatL10n.tr("按名称", "Name")
        case .path: return ZtatL10n.tr("按路径", "Path")
        }
    }
}

public enum AppArchitecture: String, Codable, Sendable {
    case arm64
    case x86_64
    case universal
    case unknown

    public var badgeLabel: String {
        switch self {
        case .arm64: return "Apple Silicon"
        case .x86_64: return "Intel"
        case .universal: return "Universal"
        case .unknown: return "Unknown"
        }
    }

    public var shortLabel: String {
        switch self {
        case .arm64: return "ARM64"
        case .x86_64: return "x86_64"
        case .universal: return "UNI"
        case .unknown: return "—"
        }
    }

    public static var hostNative: AppArchitecture {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }
}

// MARK: - Installed App Model

public struct InstalledAppEntry: Identifiable, Hashable, Sendable {
    public let id: String               // canonical standardized path
    public let url: URL
    public let actualBundleURL: URL     // inner bundle for wrapped iOS or Steam games
    public let name: String
    public let bundleIdentifier: String
    public let version: String
    public let isSystemDomain: Bool     // /Applications vs ~/Applications
    public let isNested: Bool           // inside a subfolder of /Applications
    public let isWrappediOS: Bool
    public let isWebApp: Bool
    public let isSteamGame: Bool
    public let steamAppID: String?
    public let isAppStore: Bool
    public let hasSparkle: Bool
    public let homebrewCaskToken: String?
    public let architecture: AppArchitecture
    public let teamIdentifier: String?
    public let entitlementGroups: [String]
    public let executableNames: [String]
    public let bundleSize: Int64
    public let dateCreated: Date?
    public let dateModified: Date?
    public let dateAdded: Date?
    public let lastUsedDate: Date?
    public let isAlreadyInTrash: Bool

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: InstalledAppEntry, rhs: InstalledAppEntry) -> Bool {
        lhs.id == rhs.id &&
        lhs.bundleSize == rhs.bundleSize &&
        lhs.architecture == rhs.architecture &&
        lhs.homebrewCaskToken == rhs.homebrewCaskToken &&
        lhs.isAlreadyInTrash == rhs.isAlreadyInTrash
    }
}

// MARK: - Leftover Categories & Items (13 Categories)

public enum LeftoverCategory: Int, CaseIterable, Identifiable, Codable, Sendable {
    case appBundle = 0
    case preferences
    case caches
    case applicationSupport
    case containers
    case logs
    case launchItems
    case savedState
    case internetPlugins
    case applicationScripts
    case systemFiles
    case userFiles
    case other

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .appBundle: return ZtatL10n.tr("应用本体", "Application Bundles")
        case .preferences: return ZtatL10n.tr("偏好设置", "Preferences")
        case .caches: return ZtatL10n.tr("缓存文件", "Caches")
        case .applicationSupport: return ZtatL10n.tr("应用支持数据", "Application Support")
        case .containers: return ZtatL10n.tr("沙盒与容器组", "Containers & Groups")
        case .logs: return ZtatL10n.tr("日志与崩溃报告", "Logs & Crash Reports")
        case .launchItems: return ZtatL10n.tr("启动项与守护进程", "Launch Agents & Daemons")
        case .savedState: return ZtatL10n.tr("窗口状态恢复", "Saved Application State")
        case .internetPlugins: return ZtatL10n.tr("插件与偏好面板", "Plug-Ins & PrefPanes")
        case .applicationScripts: return ZtatL10n.tr("应用脚本", "Application Scripts")
        case .systemFiles: return ZtatL10n.tr("系统级文件与收据", "System Files & Receipts")
        case .userFiles: return ZtatL10n.tr("用户配置与点文件", "User Files & Dotfiles")
        case .other: return ZtatL10n.tr("其他残留", "Other")
        }
    }

    public var symbolName: String {
        switch self {
        case .appBundle: return "app.fill"
        case .preferences: return "slider.horizontal.3"
        case .caches: return "archivebox.fill"
        case .applicationSupport: return "folder.fill"
        case .containers: return "shippingbox.fill"
        case .logs: return "doc.text.fill"
        case .launchItems: return "gearshape.2.fill"
        case .savedState: return "macwindow"
        case .internetPlugins: return "puzzlepiece.fill"
        case .applicationScripts: return "applescript.fill"
        case .systemFiles: return "internaldrive.fill"
        case .userFiles: return "person.crop.circle.fill"
        case .other: return "doc.fill"
        }
    }

    public static func classify(url: URL, isMainApp: Bool = false) -> LeftoverCategory {
        if isMainApp || url.pathExtension.lowercased() == "app" {
            return .appBundle
        }
        let path = url.path
        if path.contains("/Preferences/") || path.contains("/SyncedPreferences/") {
            return .preferences
        }
        if path.contains("/Caches/") || path.contains("/HTTPStorages/") || path.contains("/WebKit/") || path.contains("/Cookies/") || path.contains("/var/folders/") {
            return .caches
        }
        if path.contains("/Containers/") || path.contains("/Group Containers/") || path.contains("/Daemon Containers/") {
            return .containers
        }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") || path.contains("/PrivilegedHelperTools/") {
            return .launchItems
        }
        if path.contains("/Saved Application State/") {
            return .savedState
        }
        if path.contains("/Logs/") || path.contains("/CrashReporter/") || path.contains("/DiagnosticReports/") {
            return .logs
        }
        if path.contains("/Application Scripts/") {
            return .applicationScripts
        }
        if path.contains("/Internet Plug-Ins/") || path.contains("/PreferencePanes/") || path.contains("/Services/") || path.contains("/Extensions/") {
            return .internetPlugins
        }
        if path.contains("/Application Support/") {
            return .applicationSupport
        }
        if path.hasPrefix("/Library/") || path.hasPrefix("/private/") || path.hasPrefix("/usr/") || path.hasPrefix("/Users/Shared/") {
            return .systemFiles
        }
        if path.hasPrefix(NSHomeDirectory() + "/.") || path.hasPrefix(NSHomeDirectory() + "/.config/") {
            return .userFiles
        }
        return .other
    }
}

public struct LeftoverItem: Identifiable, Hashable, Sendable {
    public let id: String        // canonical path
    public let url: URL
    public let category: LeftoverCategory
    public let size: Int64
    public let matchReason: String
    public let isLinkedOrphan: Bool
    public let isContainerUUID: Bool
    public let isReadOnlyOrPrivileged: Bool
    public var isSelected: Bool

    public var name: String { url.lastPathComponent }

    public var displayPath: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Orphaned File Model

public struct OrphanedFileItem: Identifiable, Hashable, Sendable {
    public let id: String        // canonical path
    public let url: URL
    public let category: LeftoverCategory
    public let size: Int64
    public let detectedOwnerHint: String
    public var isSelected: Bool

    public var name: String { url.lastPathComponent }
    public var displayPath: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Mach-O Lipo & Localization Models

public struct LipoAppAnalysis: Identifiable, Hashable, Sendable {
    public let id: String        // app path
    public let app: InstalledAppEntry
    public let fatBinaryCount: Int
    public let reclaimableBytes: Int64
    public let isSIPProtected: Bool
    public let isAppStoreSealed: Bool
    public let detailNote: String?

    public var savingsPercent: Double {
        guard app.bundleSize > 0 else { return 0 }
        return min(100, Double(reclaimableBytes) / Double(app.bundleSize) * 100.0)
    }
}

public struct LanguageBundleItem: Identifiable, Hashable, Sendable {
    public let id: String        // language code (e.g. "fr", "ja")
    public let code: String
    public let displayName: String
    public let urls: [URL]
    public let totalSize: Int64
    public let isPreferred: Bool
    public var isSelectedForRemoval: Bool
}

// MARK: - Developer Environment Models

public struct DevPathItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let toolchainID: String
    public let label: String
    public let url: URL
    public let size: Int64
    public var isSelected: Bool

    public var displayPath: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

public struct DevToolchainGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let symbolName: String
    public let items: [DevPathItem]

    public var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }
}

public struct OrphanedIDEWorkspace: Identifiable, Hashable, Sendable {
    public let id: String
    public let ideName: String
    public let storageURL: URL
    public let missingProjectPath: String
    public let size: Int64
    public var isSelected: Bool
}

public struct PipPackageItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let size: Int64
    public var isSelected: Bool
}

// MARK: - PKG / Receipts Models

public struct PackageBOMEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let exists: Bool
    public let size: Int64
    public let isProtectedSystemRoot: Bool
    public var isSelected: Bool
    /// A payload directory offered only because it would be empty after the package's own
    /// files are removed. Never pre-selected.
    public var isDirectory: Bool = false
}

public struct PackageReceiptItem: Identifiable, Hashable, Sendable {
    public let id: String            // package identifier
    public let packageID: String
    public let displayName: String
    public let version: String
    public let installDate: Date?
    public let installPrefix: String
    public let volume: String
    public let receiptPlistURL: URL?
    public let receiptBomURL: URL?
    public let estimatedSize: Int64
}

// MARK: - Plugins Manager (18 Categories)

public enum PluginCategory: String, CaseIterable, Identifiable, Sendable {
    case audio
    case preferencePanes
    case quickLook
    case screenSavers
    case internetPlugIns
    case coreImage
    case colorPickers
    case fonts
    case dictionaries
    case automator
    case safariExtensions
    case motionTemplates
    case spotlight
    case services
    case addressBook
    case contextualMenu
    case inputMethods
    case widgets

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .audio: return ZtatL10n.tr("音频插件 (AU/VST/VST3/HAL)", "Audio (AU/VST/VST3/HAL)")
        case .preferencePanes: return ZtatL10n.tr("系统偏好面板", "Preference Panes")
        case .quickLook: return ZtatL10n.tr("快速查看 (QuickLook)", "QuickLook Generators")
        case .screenSavers: return ZtatL10n.tr("屏幕保护程序", "Screen Savers")
        case .internetPlugIns: return ZtatL10n.tr("浏览器插件", "Internet Plug-Ins")
        case .coreImage: return "Core Image Units"
        case .colorPickers: return ZtatL10n.tr("取色器扩展", "Color Pickers")
        case .fonts: return ZtatL10n.tr("用户字体", "User Fonts")
        case .dictionaries: return ZtatL10n.tr("词典扩展", "Dictionaries")
        case .automator: return ZtatL10n.tr("自动操作 (Automator)", "Automator Workflows")
        case .safariExtensions: return ZtatL10n.tr("Safari 扩展", "Safari Extensions")
        case .motionTemplates: return ZtatL10n.tr("Motion / FCP 模板", "Motion / FCP Templates")
        case .spotlight: return ZtatL10n.tr("聚焦索引插件 (Spotlight)", "Spotlight Importers")
        case .services: return ZtatL10n.tr("访达服务", "Finder Services")
        case .addressBook: return ZtatL10n.tr("通讯录插件", "Address Book Plug-Ins")
        case .contextualMenu: return ZtatL10n.tr("右键菜单插件", "Contextual Menu Items")
        case .inputMethods: return ZtatL10n.tr("第三方输入法", "Input Methods")
        case .widgets: return ZtatL10n.tr("桌面小组件", "Widgets")
        }
    }

    public var symbolName: String {
        switch self {
        case .audio: return "waveform"
        case .preferencePanes: return "slider.horizontal.below.rectangle"
        case .quickLook: return "eye"
        case .screenSavers: return "sparkles.tv"
        case .internetPlugIns: return "globe"
        case .coreImage: return "camera.filters"
        case .colorPickers: return "eyedropper"
        case .fonts: return "textformat"
        case .dictionaries: return "book.closed"
        case .automator: return "gearshape.arrow.triangle.2.circlepath"
        case .safariExtensions: return "safari"
        case .motionTemplates: return "film"
        case .spotlight: return "magnifyingglass"
        case .services: return "wand.and.stars"
        case .addressBook: return "person.crop.rectangle"
        case .contextualMenu: return "contextualmenu.and.cursorarrow"
        case .inputMethods: return "keyboard"
        case .widgets: return "square.grid.2x2"
        }
    }
}

public struct PluginItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let category: PluginCategory
    public let bundleIdentifier: String?
    public let isSystemDomain: Bool
    public let size: Int64
    public let modifiedDate: Date?
    public var isSelected: Bool

    public var displayPath: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Launch Services / Daemons Models

public enum LaunchServiceKind: String, CaseIterable, Identifiable, Sendable {
    case userAgent
    case globalAgent
    case globalDaemon
    case embeddedHelper
    case xpcService
    case runtimeOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .userAgent: return ZtatL10n.tr("用户代理 (LaunchAgent)", "User LaunchAgent")
        case .globalAgent: return ZtatL10n.tr("系统代理 (LaunchAgent)", "Global LaunchAgent")
        case .globalDaemon: return ZtatL10n.tr("系统守护 (LaunchDaemon)", "System LaunchDaemon")
        case .embeddedHelper: return ZtatL10n.tr("应用内嵌服务", "Embedded App Service")
        case .xpcService: return "XPC Service"
        case .runtimeOnly: return ZtatL10n.tr("仅运行时任务", "Runtime Only")
        }
    }
}

public struct LaunchServiceItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let kind: LaunchServiceKind
    public let plistURL: URL?
    public let associatedAppURL: URL?
    public let programPath: String?
    public let pid: Int32?
    public let lastExitStatus: Int32?
    public let isLoaded: Bool
    public let runAtLoad: Bool

    public var isRunning: Bool {
        isLoaded && (pid ?? 0) > 0
    }

    /// LaunchDaemons live in launchd's `system` domain. Every agent — including the global
    /// ones in `/Library/LaunchAgents` — runs per user in `gui/<uid>`.
    public var runsInSystemDomain: Bool {
        switch kind {
        case .globalDaemon:
            return true
        case .embeddedHelper:
            return plistURL?.path.contains("/Contents/Library/LaunchDaemons/") ?? false
        case .userAgent, .globalAgent, .xpcService, .runtimeOnly:
            return false
        }
    }

    /// launchd domain this job is managed in (`system` or `gui/<uid>`).
    public var launchdDomain: String {
        runsInSystemDomain ? "system" : "gui/\(getuid())"
    }

    /// `<domain>/<label>` service target for `launchctl kickstart/bootout/print`.
    public var launchdServiceTarget: String {
        "\(launchdDomain)/\(label)"
    }

    /// Whether `launchctl` operations on this job need root (system-domain jobs only).
    public var requiresElevation: Bool {
        runsInSystemDomain
    }

    /// Whether moving the job's plist to the Trash needs administrator rights.
    public var plistRemovalRequiresAdmin: Bool {
        guard let path = plistURL?.path else { return false }
        return path.hasPrefix("/Library/") || path.hasPrefix("/System/")
    }
}

// MARK: - File Search Models

public enum FileSearchKindFilter: String, CaseIterable, Identifiable, Sendable {
    case any
    case filesOnly
    case foldersOnly
    case packagesOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: return ZtatL10n.tr("全部类型", "Files & Folders")
        case .filesOnly: return ZtatL10n.tr("仅文件", "Files Only")
        case .foldersOnly: return ZtatL10n.tr("仅文件夹", "Folders Only")
        case .packagesOnly: return ZtatL10n.tr("仅包 (.app/.pkg)", "Packages Only")
        }
    }
}

public enum FileNameMatchMode: String, CaseIterable, Identifiable, Sendable {
    case contains
    case startsWith
    case endsWith
    case exact
    case regex
    case doesNotContain

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .contains: return ZtatL10n.tr("包含", "Contains")
        case .startsWith: return ZtatL10n.tr("开头为", "Starts With")
        case .endsWith: return ZtatL10n.tr("结尾为", "Ends With")
        case .exact: return ZtatL10n.tr("完全匹配", "Equals")
        case .regex: return ZtatL10n.tr("正则", "Regex")
        case .doesNotContain: return ZtatL10n.tr("不包含", "Doesn't Contain")
        }
    }
}

public struct FileSearchQuery: Sendable {
    public var rootURL: URL
    public var nameText: String = ""
    public var nameMatchMode: FileNameMatchMode = .contains
    public var extensionsCSV: String = ""
    public var minSizeBytes: Int64?
    public var maxSizeBytes: Int64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var finderTagFilter: String = ""
    public var finderCommentFilter: String = ""
    public var kindFilter: FileSearchKindFilter = .any
    public var includeSubfolders: Bool = true
    public var includeHidden: Bool = false
    public var caseSensitive: Bool = false
    public var excludeSystemFolders: Bool = true
    public var maxResults: Int = 2000

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }
}

public struct FileSearchResultItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let size: Int64
    public let modifiedDate: Date?
    public let finderTags: [String]
    public let finderComment: String?
    public var isSelected: Bool

    public var displayPath: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Delete History / Undo Models

public struct TrashedFilePair: Codable, Hashable, Sendable {
    public let originalPath: String
    public let trashedPath: String
    public let sizeBytes: Int64
}

public struct DeleteHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let operationTitle: String
    public let sourceModule: String
    public let trashBundlePath: String
    public let files: [TrashedFilePair]
    public let totalBytes: Int64

    public var bundleStillExistsInTrash: Bool {
        FileManager.default.fileExists(atPath: trashBundlePath)
    }
}

// MARK: - TCC Permissions & Disk Volume Models

public struct TCCPermissionRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let serviceKey: String
    public let serviceName: String
    public let scope: String         // "User" or "System"
    public let statusLabel: String
    public let isAllowed: Bool
    public let reasonLabel: String
    public let lastModified: Date?
}

public struct DiskVolumeInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let mountURL: URL
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let opportunisticAvailableBytes: Int64
    public let isRootVolume: Bool
    public let isRemovable: Bool

    public var usedBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }

    public var purgeableBytes: Int64 {
        max(0, opportunisticAvailableBytes - availableBytes)
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(totalBytes)))
    }
}

// MARK: - Console Log Line

public struct CleanerConsoleEntry: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let section: String
    public let message: String
    public let isError: Bool
}

// MARK: - Formatting Helpers

public enum CleanerFormatters {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    public static func normalizedToken(_ raw: String) -> String {
        let lower = raw.lowercased()
        let scalars = lower.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let out = String(String.UnicodeScalarView(scalars))
        return out.isEmpty ? lower : out
    }
}
