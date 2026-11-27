// SPDX-License-Identifier: GPL-3.0-or-later
// Public host facade bridging ZtatCleaner into ztat's unified Settings window,
// Hub menu, Finder Services, URL scheme, and zero-idle lifecycle.

import AppKit
import Combine
import Foundation
import SwiftUI
import ZtatCore

@MainActor
public final class ZtatCleanerHost: ObservableObject {
    public static let shared = ZtatCleanerHost()

    @Published public private(set) var installedApps: [InstalledAppEntry] = []
    @Published public private(set) var isLoadingApps: Bool = false
    @Published public private(set) var hasLoadedAppsOnce: Bool = false
    @Published public private(set) var diskVolumes: [DiskVolumeInfo] = []

    @Published public var selectedApp: InstalledAppEntry? = nil
    @Published public var multiSelectedAppIDs: Set<String> = []
    @Published public var externalQueue: [URL] = []

    @Published public private(set) var leftovers: [LeftoverItem] = []
    @Published public private(set) var isScanningLeftovers: Bool = false
    @Published public private(set) var isPerformingAction: Bool = false
    @Published public var activeSensitivityOverride: CleanerSearchSensitivity? = nil

    @Published public private(set) var consoleLogs: [CleanerConsoleEntry] = []
    @Published public var statusBanner: String? = nil
    @Published public var statusBannerIsError: Bool = false

    private var isStarted = false
    private var cancellables = Set<AnyCancellable>()
    private var leftoverScanTask: Task<Void, Never>?
    private var bannerClearTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle (Strict Zero-Idle)

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        // Sync Sentinel strictly with saved opt-in preference (OFF by default -> zero FSEvents).
        TrashSentinelMonitor.shared.syncWithSettings()

        CleanerSettingsStore.shared.$sentinelEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                TrashSentinelMonitor.shared.syncWithSettings()
            }
            .store(in: &cancellables)
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        leftoverScanTask?.cancel()
        leftoverScanTask = nil
        bannerClearTask?.cancel()
        bannerClearTask = nil
        cancellables.removeAll()
        TrashSentinelMonitor.shared.stop()
    }

    // MARK: - Sidebar Descriptors & Embedded SwiftUI Views

    public func settingsSectionItems() -> [ZtatCleanerSectionItem] {
        CleanerSectionID.allCases.map { section in
            ZtatCleanerSectionItem(
                id: section.id,
                title: section.title,
                symbolName: section.symbolName,
                keywords: section.searchKeywords
            )
        }
    }

    public static func normalizeSectionID(_ raw: String?) -> String {
        guard let raw, let valid = CleanerSectionID(rawValue: raw) else {
            return CleanerSectionID.apps.rawValue
        }
        return valid.rawValue
    }

    public func makeSettingsDetailView(sectionID: String) -> AnyView {
        let section = CleanerSectionID(rawValue: sectionID) ?? .apps
        switch section {
        case .apps:
            return AnyView(CleanerAppsUninstallerView(host: self))
        case .orphans:
            return AnyView(CleanerOrphansView(host: self))
        case .lipo:
            return AnyView(CleanerLipoView(host: self))
        case .developer:
            return AnyView(CleanerDeveloperView(host: self))
        case .packages:
            return AnyView(CleanerPackagesView(host: self))
        case .plugins:
            return AnyView(CleanerPluginsView(host: self))
        case .services:
            return AnyView(CleanerServicesView(host: self))
        case .fileSearch:
            return AnyView(CleanerFileSearchView(host: self))
        case .history:
            return AnyView(CleanerDeleteHistoryView(host: self))
        case .settings:
            return AnyView(CleanerSettingsView(host: self))
        }
    }

    // MARK: - Deep Link / Finder Service / Trash Sentinel / Drag-Drop Routing

    /// Opens ztat's App Uninstaller pre-targeted on an arbitrary `.app` bundle (even inside `~/.Trash`).
    /// Protected apps (macOS system apps, `com.apple.*`, ztat itself) are refused with a visible message,
    /// whichever entry point (deep link, drag-and-drop, Finder Service, Trash Sentinel) supplied them.
    public func openUninstaller(for appURL: URL) {
        let clean = appURL.standardizedFileURL
        guard clean.pathExtension.lowercased() == "app" else { return }
        NotificationCenter.default.post(name: .ztatOpenSettings, object: ZtatSettingsRoute.cleaner(sectionID: CleanerSectionID.apps.rawValue))
        if let reason = AppDiscoveryEngine.shared.restrictionReason(forAppAt: clean) {
            rejectProtectedApp(at: clean, reason: reason)
            return
        }
        Task { @MainActor in
            if !hasLoadedAppsOnce {
                await refreshInstalledApps()
            }
            if let existing = installedApps.first(where: { $0.id == clean.path }) {
                if let reason = AppDiscoveryEngine.shared.restrictionReason(for: existing) {
                    rejectProtectedApp(at: clean, reason: reason)
                } else {
                    selectApp(existing)
                }
                return
            }
            switch await AppDiscoveryEngine.shared.inspectSingleAppForUninstall(at: clean) {
            case .accepted(let inspected):
                selectApp(inspected)
            case .rejected(let reason):
                rejectProtectedApp(at: clean, reason: reason)
            case .unreadable:
                let message = ZtatL10n.tr(
                    "无法读取应用：\(clean.lastPathComponent)",
                    "Could not read app bundle: \(clean.lastPathComponent)"
                )
                appendLog(section: "Apps", message: message, isError: true)
                showBanner(message, isError: true)
            }
        }
    }

    private func rejectProtectedApp(at url: URL, reason: String) {
        appendLog(section: "Apps", message: "\(reason) (\(url.path))", isError: true)
        showBanner(reason, isError: true)
    }

    /// Handles `ztat://uninstall?path=...` and `ztat://cleaner?section=...` deep links.
    @discardableResult
    public func handleIncomingURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "ztat" else { return false }
        let host = (url.host ?? "").lowercased()
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = Dictionary((comps?.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { first, _ in first })

        switch host {
        case "uninstall", "openapp":
            if let path = params["path"], !path.isEmpty {
                let expanded = (path as NSString).expandingTildeInPath
                // Only absolute paths are accepted; relative paths would resolve against ztat's CWD.
                guard expanded.hasPrefix("/") else { return false }
                openUninstaller(for: URL(fileURLWithPath: expanded))
                return true
            }
            NotificationCenter.default.post(name: .ztatOpenSettings, object: ZtatSettingsRoute.cleaner(sectionID: CleanerSectionID.apps.rawValue))
            return true
        case "cleaner":
            let sec = Self.normalizeSectionID(params["section"])
            NotificationCenter.default.post(name: .ztatOpenSettings, object: ZtatSettingsRoute.cleaner(sectionID: sec))
            return true
        default:
            return false
        }
    }

    // MARK: - App Discovery & Leftover Scanning

    public func ensureAppsLoaded() {
        if diskVolumes.isEmpty {
            refreshDiskVolumes()
        }
        guard !hasLoadedAppsOnce && !isLoadingApps else { return }
        Task { @MainActor in
            await refreshInstalledApps()
        }
    }

    public func refreshDiskVolumes() {
        diskVolumes = AppDiscoveryEngine.shared.loadDiskVolumes()
    }

    public func refreshInstalledApps() async {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        refreshDiskVolumes()
        let folders = CleanerSettingsStore.shared.appScanFolders
        appendLog(section: "Apps", message: ZtatL10n.tr("正在扫描已安装应用…", "Scanning installed applications…"))
        let found = await AppDiscoveryEngine.shared.discoverApps(in: folders)
        installedApps = found
        hasLoadedAppsOnce = true
        isLoadingApps = false
        appendLog(section: "Apps", message: ZtatL10n.tr("已发现 \(found.count) 个应用程序。", "Discovered \(found.count) applications."))

        // Refresh currently selected app reference if still installed
        if let current = selectedApp, !current.isAlreadyInTrash {
            if let updated = found.first(where: { $0.id == current.id }) {
                selectedApp = updated
            } else {
                selectedApp = nil
                leftovers = []
            }
        }
    }

    public func selectApp(_ app: InstalledAppEntry?) {
        selectedApp = app
        activeSensitivityOverride = nil
        leftoverScanTask?.cancel()
        guard app != nil else {
            leftovers = []
            isScanningLeftovers = false
            return
        }
        rescanSelectedAppLeftovers()
    }

    public func rescanSelectedAppLeftovers() {
        guard let app = selectedApp else {
            leftovers = []
            return
        }
        leftoverScanTask?.cancel()
        isScanningLeftovers = true
        let sensitivity = activeSensitivityOverride ?? CleanerSettingsStore.shared.sensitivity
        let exclusions = CleanerSettingsStore.shared.appExclusions
        let linked = CleanerSettingsStore.shared.linkedOrphans(forAppPath: app.id)
        let snapshotApps = installedApps

        appendLog(section: "Apps", message: ZtatL10n.tr("正在扫描 \(app.name) 的关联文件（灵敏度：\(sensitivity.title)）…", "Scanning leftovers for \(app.name) (\(sensitivity.title))…"))

        leftoverScanTask = Task { @MainActor [weak self] in
            let found = await LeftoverScannerEngine.shared.scanLeftovers(
                for: app,
                allInstalledApps: snapshotApps,
                sensitivity: sensitivity,
                customExclusions: exclusions,
                linkedOrphanPaths: linked
            )
            guard !Task.isCancelled, let self, self.selectedApp?.id == app.id else { return }
            self.leftovers = found
            self.isScanningLeftovers = false
            let totalBytes = found.reduce(Int64(0)) { $0 + $1.size }
            self.appendLog(section: "Apps", message: ZtatL10n.tr(
                "找到 \(found.count) 项，总计 \(CleanerFormatters.bytes(totalBytes))。",
                "Found \(found.count) items totaling \(CleanerFormatters.bytes(totalBytes))."
            ))
        }
    }

    public func setLeftoverSelected(_ selected: Bool, id: String) {
        guard let idx = leftovers.firstIndex(where: { $0.id == id }) else { return }
        leftovers[idx].isSelected = selected
    }

    public func setCategorySelected(_ selected: Bool, category: LeftoverCategory) {
        for idx in leftovers.indices where leftovers[idx].category == category {
            leftovers[idx].isSelected = selected
        }
    }

    public func selectAllLeftovers(_ selected: Bool) {
        for idx in leftovers.indices {
            if leftovers[idx].category == .appBundle && selectedApp?.isAlreadyInTrash == true {
                leftovers[idx].isSelected = false
            } else {
                leftovers[idx].isSelected = selected
            }
        }
    }

    /// 1-click Reset App preset: unchecks `.app` bundle and selects all preferences/caches/containers/support data.
    public func applyResetAppSelectionPreset() {
        for idx in leftovers.indices {
            leftovers[idx].isSelected = (leftovers[idx].category != .appBundle)
        }
        showBanner(ZtatL10n.tr("已切换为“重置应用”预设（保留应用本体，仅清理配置与数据）。", "Reset App preset selected (keeps .app bundle, selects all user data)."), isError: false)
    }

    /// Executes full uninstall or partial app reset for the currently checked leftovers.
    public func executeSelectedRemoval() async {
        guard let app = selectedApp else { return }
        // Single choke point for uninstall AND reset, whichever way the app was selected (list, deep link…).
        if let reason = AppDiscoveryEngine.shared.restrictionReason(for: app) {
            rejectProtectedApp(at: app.url, reason: reason)
            return
        }
        let chosen = leftovers.filter(\.isSelected)
        guard !chosen.isEmpty else { return }

        let removingMainApp = chosen.contains { $0.category == .appBundle } || app.isAlreadyInTrash
        isPerformingAction = true
        defer { isPerformingAction = false }

        let protectedRoots = CleanerSettingsStore.shared.appScanFolders
        let outcome = await SafeDeletionEngine.shared.trashItems(
            urls: chosen.map(\.url),
            bundleLabel: removingMainApp ? app.name : "\(app.name)_Reset",
            sourceModule: "apps",
            protectedRoots: protectedRoots,
            terminateBundleID: app.bundleIdentifier.isEmpty ? nil : app.bundleIdentifier,
            onLog: { [weak self] msg, isErr in
                Task { @MainActor in
                    self?.appendLog(section: "Apps", message: msg, isError: isErr)
                }
            }
        )

        // Optional Homebrew cask --zap cleanup (opt-in, OFF by default). `--zap` deletes data permanently,
        // so it only runs once the `.app` bundle itself is confirmed to be in the Trash.
        if removingMainApp, CleanerSettingsStore.shared.homebrewZapEnabled, let cask = app.homebrewCaskToken {
            if Self.isAppBundleConfirmedInTrash(app, outcome: outcome) {
                appendLog(section: "Apps", message: "Running brew uninstall --cask \(cask) --zap --force…")
                let (ok, output) = await LeftoverScannerEngine.shared.runHomebrewCaskZap(token: cask)
                appendLog(section: "Apps", message: ok ? "Homebrew cask \(cask) removed." : "Homebrew zap note: \(output)", isError: !ok)
            } else {
                appendLog(section: "Apps", message: ZtatL10n.tr(
                    "未确认 \(app.name) 已移入废纸篓，已跳过 Homebrew --zap（\(cask)）。",
                    "Skipped Homebrew --zap for \(cask): \(app.name) was not confirmed in the Trash."
                ), isError: true)
            }
        }

        if outcome.failedItems.isEmpty {
            showBanner(ZtatL10n.tr(
                "已安全移入废纸篓：\(outcome.succeededCount) 项，释放 \(CleanerFormatters.bytes(outcome.freedBytes))（可在「清理历史」随时还原）。",
                "Moved \(outcome.succeededCount) items (\(CleanerFormatters.bytes(outcome.freedBytes))) to Trash (restorable in Delete History)."
            ), isError: false)
        } else {
            showBanner(ZtatL10n.tr(
                "完成 \(outcome.succeededCount) 项，\(outcome.failedItems.count) 项失败：\(outcome.failedItems.first?.reason ?? "")",
                "Moved \(outcome.succeededCount) items, \(outcome.failedItems.count) failed: \(outcome.failedItems.first?.reason ?? "")"
            ), isError: true)
        }

        // Only treat the app as uninstalled once its bundle is really gone from its original location
        // (the trash step may refuse everything, e.g. when the app would not quit).
        let mainAppRemoved = removingMainApp
            && (app.isAlreadyInTrash || !FileManager.default.fileExists(atPath: app.url.standardizedFileURL.path))
        if mainAppRemoved {
            installedApps.removeAll { $0.id == app.id }
            multiSelectedAppIDs.remove(app.id)
            // Drop the removed app before routing on, so a rejected/unreadable next target never
            // leaves the just-removed app selected.
            selectedApp = nil
            leftovers = []
            if let nextURL = externalQueue.first {
                externalQueue.removeFirst()
                openUninstaller(for: nextURL)
            } else if let nextID = multiSelectedAppIDs.first,
                      let nextApp = installedApps.first(where: { $0.id == nextID }) {
                selectApp(nextApp)
            }
            refreshDiskVolumes()
        } else {
            rescanSelectedAppLeftovers()
        }
    }

    /// True only when the trash step verifiably moved `app`'s bundle into the Trash (or it already lived
    /// there): the outcome records the bundle path, the trashed copy exists and the original is gone.
    private static func isAppBundleConfirmedInTrash(_ app: InstalledAppEntry, outcome: SafeDeletionOutcome) -> Bool {
        let fm = FileManager.default
        let appPath = app.url.standardizedFileURL.path
        func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

        if outcome.failedItems.contains(where: { standardized($0.path) == appPath }) {
            return false
        }
        if let pair = outcome.entry?.files.first(where: { standardized($0.originalPath) == appPath }) {
            return fm.fileExists(atPath: pair.trashedPath) && !fm.fileExists(atPath: appPath)
        }
        if app.isAlreadyInTrash {
            let trashRoot = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL.path
            return appPath.hasPrefix(trashRoot + "/") && fm.fileExists(atPath: appPath)
        }
        return false
    }

    // MARK: - Logging & Banner Helpers

    public func appendLog(section: String, message: String, isError: Bool = false) {
        let entry = CleanerConsoleEntry(timestamp: Date(), section: section, message: message, isError: isError)
        consoleLogs.append(entry)
        if consoleLogs.count > 300 {
            consoleLogs.removeFirst(consoleLogs.count - 300)
        }
    }

    public func clearConsole() {
        consoleLogs.removeAll()
    }

    public func showBanner(_ text: String, isError: Bool) {
        statusBanner = text
        statusBannerIsError = isError
        bannerClearTask?.cancel()
        bannerClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.statusBanner = nil
        }
    }
}
