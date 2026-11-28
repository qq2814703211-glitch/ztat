// SPDX-License-Identifier: GPL-3.0-or-later
// Isolated preference persistence for ZtatCleaner (`dev.ztat.app.cleaner`).

import Combine
import Foundation
import ZtatCore

@MainActor
public final class CleanerSettingsStore: ObservableObject {
    public static let shared = CleanerSettingsStore()

    public let defaults: UserDefaults

    private enum Keys {
        static let sensitivity = "sensitivity"
        static let deepSearchFileContents = "deepSearchFileContents"
        static let sentinelEnabled = "sentinelEnabled"
        static let homebrewZapEnabled = "homebrewZapEnabled"
        static let confirmBeforeDelete = "confirmBeforeDelete"
        static let lockDefaultAppPaths = "lockDefaultAppPaths"
        static let appScanFolders = "appScanFolders"
        static let appExclusions = "appExclusions"
        static let orphanExclusions = "orphanExclusions"
        static let linkedOrphans = "linkedOrphans"
        static let lipoExcludedAppPaths = "lipoExcludedAppPaths"
        static let lipoPruneTranslations = "lipoPruneTranslations"
        static let lipoMinSavings1MB = "lipoMinSavings1MB"
        static let lipoShowZeroSavings = "lipoShowZeroSavings"
        static let lipoTotalSavedBytes = "lipoTotalSavedBytes"
        static let keepLanguageCodes = "keepLanguageCodes"
        static let preferCategorizedFiles = "preferCategorizedFiles"
        static let preferGridAppList = "preferGridAppList"
        static let consoleOpen = "consoleOpen"
        static let sysDataScanExternalVolumes = "sysDataScanExternalVolumes"
        static let sysDataRequireAuth = "sysDataRequireAuth"
        static let sysDataHistoryEnabled = "sysDataHistoryEnabled"
        static let sysDataHiddenIDs = "sysDataHiddenIDs"
    }

    public static var defaultAppScanFolders: [String] {
        [
            "/Applications",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        ]
    }

    @Published public var sensitivity: CleanerSearchSensitivity {
        didSet { defaults.set(sensitivity.rawValue, forKey: Keys.sensitivity) }
    }

    @Published public var deepSearchFileContents: Bool {
        didSet { defaults.set(deepSearchFileContents, forKey: Keys.deepSearchFileContents) }
    }

    /// Strict zero-idle default: OFF unless explicitly enabled by user.
    @Published public var sentinelEnabled: Bool {
        didSet {
            defaults.set(sentinelEnabled, forKey: Keys.sentinelEnabled)
            NotificationCenter.default.post(name: .ztatCleanerDidChange, object: nil)
        }
    }

    @Published public var homebrewZapEnabled: Bool {
        didSet { defaults.set(homebrewZapEnabled, forKey: Keys.homebrewZapEnabled) }
    }

    @Published public var confirmBeforeDelete: Bool {
        didSet { defaults.set(confirmBeforeDelete, forKey: Keys.confirmBeforeDelete) }
    }

    @Published public var lockDefaultAppPaths: Bool {
        didSet {
            defaults.set(lockDefaultAppPaths, forKey: Keys.lockDefaultAppPaths)
            if lockDefaultAppPaths {
                ensureDefaultAppFoldersPresent()
            }
        }
    }

    @Published public var appScanFolders: [String] {
        didSet { defaults.set(appScanFolders, forKey: Keys.appScanFolders) }
    }

    @Published public var appExclusions: [String] {
        didSet { defaults.set(appExclusions, forKey: Keys.appExclusions) }
    }

    @Published public var orphanExclusions: [String] {
        didSet { defaults.set(orphanExclusions, forKey: Keys.orphanExclusions) }
    }

    /// Maps canonical `.app` path -> array of manually linked orphan file paths.
    @Published public var linkedOrphansByApp: [String: [String]] {
        didSet {
            if let data = try? JSONEncoder().encode(linkedOrphansByApp) {
                defaults.set(data, forKey: Keys.linkedOrphans)
            }
        }
    }

    @Published public var lipoExcludedAppPaths: Set<String> {
        didSet { defaults.set(Array(lipoExcludedAppPaths).sorted(), forKey: Keys.lipoExcludedAppPaths) }
    }

    @Published public var lipoPruneTranslations: Bool {
        didSet { defaults.set(lipoPruneTranslations, forKey: Keys.lipoPruneTranslations) }
    }

    @Published public var lipoMinSavings1MB: Bool {
        didSet { defaults.set(lipoMinSavings1MB, forKey: Keys.lipoMinSavings1MB) }
    }

    @Published public var lipoShowZeroSavings: Bool {
        didSet { defaults.set(lipoShowZeroSavings, forKey: Keys.lipoShowZeroSavings) }
    }

    @Published public var lipoTotalSavedBytes: Int64 {
        didSet { defaults.set(lipoTotalSavedBytes, forKey: Keys.lipoTotalSavedBytes) }
    }

    /// Preferred `.lproj` language prefixes preserved during auto-prune (always keeps Base + English fallback).
    @Published public var keepLanguageCodes: [String] {
        didSet { defaults.set(keepLanguageCodes, forKey: Keys.keepLanguageCodes) }
    }

    @Published public var preferCategorizedFiles: Bool {
        didSet { defaults.set(preferCategorizedFiles, forKey: Keys.preferCategorizedFiles) }
    }

    @Published public var preferGridAppList: Bool {
        didSet { defaults.set(preferGridAppList, forKey: Keys.preferGridAppList) }
    }

    @Published public var isConsoleOpen: Bool {
        didSet { defaults.set(isConsoleOpen, forKey: Keys.consoleOpen) }
    }

    @Published public var sysDataScanExternalVolumes: Bool {
        didSet { defaults.set(sysDataScanExternalVolumes, forKey: Keys.sysDataScanExternalVolumes) }
    }

    @Published public var sysDataRequireAuth: Bool {
        didSet { defaults.set(sysDataRequireAuth, forKey: Keys.sysDataRequireAuth) }
    }

    @Published public var sysDataHistoryEnabled: Bool {
        didSet { defaults.set(sysDataHistoryEnabled, forKey: Keys.sysDataHistoryEnabled) }
    }

    @Published public var sysDataHiddenIDs: Set<String> {
        didSet { defaults.set(Array(sysDataHiddenIDs).sorted(), forKey: Keys.sysDataHiddenIDs) }
    }

    public init(suiteName: String = ZtatBrand.cleanerDefaultsSuite) {
        let store = UserDefaults(suiteName: suiteName) ?? .standard
        self.defaults = store

        let sensRaw = store.object(forKey: Keys.sensitivity) as? Int ?? CleanerSearchSensitivity.strict.rawValue
        self.sensitivity = CleanerSearchSensitivity(rawValue: sensRaw) ?? .strict
        self.deepSearchFileContents = store.bool(forKey: Keys.deepSearchFileContents)
        self.sentinelEnabled = store.bool(forKey: Keys.sentinelEnabled)
        self.homebrewZapEnabled = store.object(forKey: Keys.homebrewZapEnabled) as? Bool ?? false
        self.confirmBeforeDelete = store.object(forKey: Keys.confirmBeforeDelete) as? Bool ?? true
        self.lockDefaultAppPaths = store.object(forKey: Keys.lockDefaultAppPaths) as? Bool ?? true

        if let savedFolders = store.stringArray(forKey: Keys.appScanFolders), !savedFolders.isEmpty {
            self.appScanFolders = savedFolders
        } else {
            self.appScanFolders = Self.defaultAppScanFolders
        }

        self.appExclusions = store.stringArray(forKey: Keys.appExclusions) ?? []
        self.orphanExclusions = store.stringArray(forKey: Keys.orphanExclusions) ?? []

        if let data = store.data(forKey: Keys.linkedOrphans),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.linkedOrphansByApp = decoded
        } else {
            self.linkedOrphansByApp = [:]
        }

        self.lipoExcludedAppPaths = Set(store.stringArray(forKey: Keys.lipoExcludedAppPaths) ?? [])
        self.lipoPruneTranslations = store.bool(forKey: Keys.lipoPruneTranslations)
        self.lipoMinSavings1MB = store.object(forKey: Keys.lipoMinSavings1MB) as? Bool ?? true
        self.lipoShowZeroSavings = store.bool(forKey: Keys.lipoShowZeroSavings)
        self.lipoTotalSavedBytes = Int64(store.integer(forKey: Keys.lipoTotalSavedBytes))

        if let langs = store.stringArray(forKey: Keys.keepLanguageCodes), !langs.isEmpty {
            self.keepLanguageCodes = langs
        } else {
            var initial: [String] = []
            for preferred in Locale.preferredLanguages.prefix(3) {
                let norm = Self.normalizeLanguageCode(preferred)
                if !initial.contains(norm) { initial.append(norm) }
            }
            if !initial.contains("en") { initial.append("en") }
            self.keepLanguageCodes = initial
        }

        self.preferCategorizedFiles = store.object(forKey: Keys.preferCategorizedFiles) as? Bool ?? true
        self.preferGridAppList = store.bool(forKey: Keys.preferGridAppList)
        self.isConsoleOpen = store.bool(forKey: Keys.consoleOpen)
        self.sysDataScanExternalVolumes = store.bool(forKey: Keys.sysDataScanExternalVolumes)
        self.sysDataRequireAuth = store.bool(forKey: Keys.sysDataRequireAuth)
        self.sysDataHistoryEnabled = store.object(forKey: Keys.sysDataHistoryEnabled) as? Bool ?? true
        self.sysDataHiddenIDs = Set(store.stringArray(forKey: Keys.sysDataHiddenIDs) ?? [])
    }

    public nonisolated static func normalizeLanguageCode(_ raw: String) -> String {
        let lower = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        if lower.hasPrefix("zh-hans") || lower == "zh-cn" || lower == "zh-sg" { return "zh-Hans" }
        if lower.hasPrefix("zh-hant") || lower == "zh-tw" || lower == "zh-hk" || lower == "zh-mo" { return "zh-Hant" }
        return lower.split(separator: "-").first.map(String.init) ?? lower
    }

    public func ensureDefaultAppFoldersPresent() {
        var updated = appScanFolders
        for folder in Self.defaultAppScanFolders where !updated.contains(folder) {
            updated.insert(folder, at: 0)
        }
        if updated != appScanFolders {
            appScanFolders = updated
        }
    }

    public func addAppScanFolder(_ path: String) {
        let standardized = (path as NSString).standardizingPath
        guard !standardized.isEmpty, !appScanFolders.contains(standardized) else { return }
        appScanFolders.append(standardized)
    }

    public func removeAppScanFolder(_ path: String) {
        if lockDefaultAppPaths && Self.defaultAppScanFolders.contains(path) { return }
        appScanFolders.removeAll { $0 == path }
        if appScanFolders.isEmpty {
            appScanFolders = Self.defaultAppScanFolders
        }
    }

    public func addAppExclusion(_ tokenOrPath: String) {
        let trimmed = tokenOrPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !appExclusions.contains(trimmed) else { return }
        appExclusions.append(trimmed)
    }

    public func removeAppExclusion(_ tokenOrPath: String) {
        appExclusions.removeAll { $0 == tokenOrPath }
    }

    public func addOrphanExclusion(_ tokenOrPath: String) {
        let trimmed = tokenOrPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !orphanExclusions.contains(trimmed) else { return }
        orphanExclusions.append(trimmed)
    }

    public func removeOrphanExclusion(_ tokenOrPath: String) {
        orphanExclusions.removeAll { $0 == tokenOrPath }
    }

    public func linkOrphan(_ filePath: String, toAppPath appPath: String) {
        let canonicalFile = (filePath as NSString).standardizingPath
        let canonicalApp = (appPath as NSString).standardizingPath
        var list = linkedOrphansByApp[canonicalApp] ?? []
        if !list.contains(canonicalFile) {
            list.append(canonicalFile)
            linkedOrphansByApp[canonicalApp] = list
        }
        addOrphanExclusion(canonicalFile)
    }

    public func unlinkOrphan(_ filePath: String, fromAppPath appPath: String) {
        let canonicalFile = (filePath as NSString).standardizingPath
        let canonicalApp = (appPath as NSString).standardizingPath
        guard var list = linkedOrphansByApp[canonicalApp] else { return }
        list.removeAll { $0 == canonicalFile }
        if list.isEmpty {
            linkedOrphansByApp.removeValue(forKey: canonicalApp)
        } else {
            linkedOrphansByApp[canonicalApp] = list
        }
        removeOrphanExclusion(canonicalFile)
    }

    public func linkedOrphans(forAppPath appPath: String) -> [String] {
        linkedOrphansByApp[(appPath as NSString).standardizingPath] ?? []
    }

    public func addLipoSavedBytes(_ delta: Int64) {
        guard delta > 0 else { return }
        lipoTotalSavedBytes += delta
    }

    public func resetAllPreferences() {
        defaults.removePersistentDomain(forName: ZtatBrand.cleanerDefaultsSuite)
        sensitivity = .strict
        deepSearchFileContents = false
        sentinelEnabled = false
        homebrewZapEnabled = false
        confirmBeforeDelete = true
        lockDefaultAppPaths = true
        appScanFolders = Self.defaultAppScanFolders
        appExclusions = []
        orphanExclusions = []
        linkedOrphansByApp = [:]
        lipoExcludedAppPaths = []
        lipoPruneTranslations = false
        lipoMinSavings1MB = true
        lipoShowZeroSavings = false
        lipoTotalSavedBytes = 0
        preferCategorizedFiles = true
        preferGridAppList = false
        sysDataScanExternalVolumes = false
        sysDataRequireAuth = false
        sysDataHistoryEnabled = true
        sysDataHiddenIDs = []
    }
}
