// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import Darwin
import Foundation
import os
import ServiceManagement

/// Canonical app-wide language preference shared by ztat Shell, Status, PowerGuard, Stats, and Toolbox.
public enum ZtatLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case de = "de"
    case fr = "fr"
    case es = "es"
    case ptBR = "pt-BR"
    case it = "it"
    case ru = "ru"
    case tr = "tr"
    case sk = "sk"
    case uk = "uk"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return ZtatL10n.tr("跟随系统", "System Default")
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .ptBR: return "Português (Brasil)"
        case .it: return "Italiano"
        case .ru: return "Русский"
        case .tr: return "Türkçe"
        case .sk: return "Slovenčina"
        case .uk: return "Українська"
        }
    }

    /// Maps normalized legacy/external raw language codes into a canonical `ZtatLanguagePreference`.
    public static func from(rawCode: String?) -> ZtatLanguagePreference {
        guard let raw = rawCode?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .system
        }
        if let exact = ZtatLanguagePreference(rawValue: raw) {
            return exact
        }
        let lower = raw.lowercased()
        if lower == "system" { return .system }
        if lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-hant") {
            return .zhHant
        }
        if lower.hasPrefix("zh") { return .zhHans }
        if lower.hasPrefix("en") { return .en }
        if lower.hasPrefix("pt") { return .ptBR }
        if lower.hasPrefix("ja") { return .ja }
        if lower.hasPrefix("ko") { return .ko }
        if lower.hasPrefix("de") { return .de }
        if lower.hasPrefix("fr") { return .fr }
        if lower.hasPrefix("es") { return .es }
        if lower.hasPrefix("it") { return .it }
        if lower.hasPrefix("ru") { return .ru }
        if lower.hasPrefix("tr") { return .tr }
        if lower.hasPrefix("sk") { return .sk }
        if lower.hasPrefix("uk") { return .uk }
        return .system
    }

    public var resolvedIsChinese: Bool {
        switch self {
        case .zhHans, .zhHant:
            return true
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("zh")
        default:
            return false
        }
    }

    /// Canonical BCP-47 language code for Vorssaint Toolbox (`AppLanguage`).
    public var toolboxLanguageCode: String? {
        switch self {
        case .system: return nil
        case .en: return "en-US"
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-TW"
        default: return rawValue
        }
    }

    /// Canonical language code for Status Trio (`Localization`).
    public var statusLanguageCode: String? {
        switch self {
        case .system: return nil
        case .en: return "en"
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .ptBR: return "pt-BR"
        case .ja, .ko, .de, .fr, .es, .it, .ru: return rawValue
        case .tr, .sk, .uk: return "en"
        }
    }
}

/// Single authoritative localization controller for all ztat subsystems.
@MainActor
public final class ZtatLocalizationStore: ObservableObject {
    public static let shared = ZtatLocalizationStore()
    public nonisolated static let defaultsKey = "ztat.appLanguage"

    private nonisolated static let cachedIsChineseLock = OSAllocatedUnfairLock(initialState: ZtatLocalizationStore.computeInitialIsChinese())

    public nonisolated static var currentIsChinese: Bool {
        cachedIsChineseLock.withLock { $0 }
    }

    @Published public var preference: ZtatLanguagePreference {
        didSet {
            guard preference != oldValue else { return }
            UserDefaults.standard.set(preference.rawValue, forKey: Self.defaultsKey)
            syncCachedStateAndNotify()
        }
    }

    @Published public private(set) var revision: Int = 0
    private var localeObserver: NSObjectProtocol?

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
            ?? UserDefaults.standard.string(forKey: "appLanguage")
        let resolved = ZtatLanguagePreference.from(rawCode: raw)
        self.preference = resolved
        Self.cachedIsChineseLock.withLock { $0 = resolved.resolvedIsChinese }

        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.preference == .system else { return }
                self.syncCachedStateAndNotify()
            }
        }
    }

    /// Allows embedded subsystems to push a change without creating a feedback loop.
    public func syncFromExternal(rawCode: String?) {
        let next = ZtatLanguagePreference.from(rawCode: rawCode)
        guard next != preference else { return }
        preference = next
    }

    private func syncCachedStateAndNotify() {
        let isZh = preference.resolvedIsChinese
        Self.cachedIsChineseLock.withLock { $0 = isZh }
        revision &+= 1
        NotificationCenter.default.post(name: .ztatLanguageDidChange, object: preference)
    }

    private nonisolated static func computeInitialIsChinese() -> Bool {
        let raw = UserDefaults.standard.string(forKey: defaultsKey)
            ?? UserDefaults.standard.string(forKey: "appLanguage")
        return ZtatLanguagePreference.from(rawCode: raw).resolvedIsChinese
    }
}

/// Single authoritative appearance controller for ztat windows and panels.
public enum ZtatAppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return ZtatL10n.tr("跟随系统", "System")
        case .light: return ZtatL10n.tr("浅色", "Light")
        case .dark: return ZtatL10n.tr("深色", "Dark")
        }
    }

    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
public final class ZtatAppearanceStore: ObservableObject {
    public static let shared = ZtatAppearanceStore()
    public static let defaultsKey = "ztat.appAppearance"

    @Published public var appearance: ZtatAppearancePreference {
        didSet {
            guard appearance != oldValue else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.defaultsKey)
            UserDefaults.standard.set(appearance.rawValue, forKey: "appAppearance")
            apply()
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
            ?? UserDefaults.standard.string(forKey: "appAppearance")
            ?? ZtatAppearancePreference.system.rawValue
        self.appearance = ZtatAppearancePreference(rawValue: raw) ?? .system
    }

    public func apply() {
        NSApp?.appearance = appearance.nsAppearance
        NotificationCenter.default.post(name: .ztatAppearanceDidChange, object: appearance)
    }
}

/// Single canonical Login Item manager (`SMAppService.mainApp`) for ztat.
@MainActor
public final class ZtatLoginItemStore: ObservableObject {
    public static let shared = ZtatLoginItemStore()

    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var requiresApproval: Bool = false
    @Published public private(set) var lastError: String? = nil

    public var isRunningFromApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private init() {
        refresh()
    }

    public func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = SMAppService.mainApp.status
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isEnabled = (status == .enabled)
                self.requiresApproval = (status == .requiresApproval)
            }
        }
    }

    public func setEnabled(_ enable: Bool) {
        lastError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var errorMessage: String?
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            let status = SMAppService.mainApp.status
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isEnabled = (status == .enabled)
                self.requiresApproval = (status == .requiresApproval)
                self.lastError = errorMessage
            }
        }
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Cross-package host bridge eliminating all `NSApp.delegate as? UpstreamAppDelegate` nil-casts.
@MainActor
public protocol ZtatHostActionHandling: AnyObject {
    func dismissHubPanel()
    func showHubPanel(tab: ZtatHubTab?)
    func openSettings(route: ZtatSettingsRoute)
    func primaryStatusItemFrame() -> NSRect?
    func relaunchApp()
    var keepsPanelOpenWhenOpeningSettings: Bool { get }
}

public final class ZtatHostBridge: @unchecked Sendable {
    public static let shared = ZtatHostBridge()
    @MainActor private weak var handler: (any ZtatHostActionHandling)?

    private init() {}

    @MainActor
    public func register(_ handler: any ZtatHostActionHandling) {
        self.handler = handler
    }

    private func runOnMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { work() }
            }
        }
    }

    public var keepsPanelOpenWhenOpeningSettings: Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { handler?.keepsPanelOpenWhenOpeningSettings ?? false }
        }
        return false
    }

    public func dismissHubPanel() {
        runOnMain { [self] in
            handler?.dismissHubPanel()
        }
    }

    public func showHubPanel(tab: ZtatHubTab? = nil) {
        runOnMain { [self] in
            handler?.showHubPanel(tab: tab)
        }
    }

    public func openSettings(route: ZtatSettingsRoute = .general) {
        runOnMain { [self] in
            if let handler {
                handler.openSettings(route: route)
            } else {
                NotificationCenter.default.post(name: .ztatOpenSettings, object: route)
            }
        }
    }

    public func primaryStatusItemFrame() -> NSRect? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { handler?.primaryStatusItemFrame() }
        }
        return nil
    }

    public func relaunchApp() {
        runOnMain { [self] in
            if let handler {
                handler.relaunchApp()
                return
            }
            Self.performDefaultRelaunch()
        }
    }

    @MainActor private static var isRelaunching: Bool = false

    @MainActor
    public static func performDefaultRelaunch() {
        guard !isRelaunching else { return }
        isRelaunching = true

        let bundlePath = Bundle.main.bundlePath
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let script = """
        waited=0
        while kill -0 "$1" 2>/dev/null && [ "$waited" -lt 100 ]; do
            sleep 0.2
            waited=$((waited + 1))
        done
        if ! kill -0 "$1" 2>/dev/null; then
            sleep 0.25
            /usr/bin/open -n "$2"
        fi
        """

        // CRITICAL: Detach into its own session via POSIX_SPAWN_SETSID so terminating ztat
        // never kills the relaunch watcher helper before it invokes `open -n`.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)

        let args = ["/bin/sh", "-c", script, "ztat-relaunch", pid, bundlePath]
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { for p in argv { free(p) } }

        var childPID: pid_t = 0
        let status = posix_spawn(&childPID, "/bin/sh", &fileActions, &attr, argv, environ)
        if status == 0 {
            NSApp?.terminate(nil)
        } else {
            isRelaunching = false
        }
    }
}
