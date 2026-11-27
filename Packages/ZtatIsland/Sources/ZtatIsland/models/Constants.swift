import ZtatCore
/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import Defaults
import KeyboardShortcuts
import Lottie
import Foundation

private let availableDirectories = FileManager
    .default
    .urls(for: .documentDirectory, in: .userDomainMask)
let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let bundleIdentifier = Bundle.main.bundleIdentifier ?? ZtatBrand.bundleIdentifier
let islandDefaults: UserDefaults = UserDefaults(suiteName: ZtatBrand.islandDefaultsSuite) ?? .standard
let appVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"

let temporaryDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
let spacing: CGFloat = 16

struct CustomVisualizer: Codable, Hashable, Equatable, Defaults.Serializable {
    let UUID: UUID
    var name: String
    var url: URL
    var speed: CGFloat = 1.0
}

struct CustomAppIcon: Codable, Hashable, Equatable, Defaults.Serializable, Identifiable {
    let id: UUID
    var name: String
    var fileName: String
    var addedAt: Date

    init(id: UUID = UUID(), name: String, fileName: String, addedAt: Date = .now) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.addedAt = addedAt
    }

    static let iconDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ztat/island", isDirectory: true)
            .appendingPathComponent("AppIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var fileURL: URL {
        Self.iconDirectory.appendingPathComponent(fileName)
    }
}

// MARK: - Custom Idle Animation Models
struct CustomIdleAnimation: Codable, Hashable, Equatable, Defaults.Serializable, Identifiable {
    let id: UUID
    var name: String
    var source: AnimationSource
    var speed: CGFloat = 1.0
    var isBuiltIn: Bool = false  // Track if it's bundled vs user-added
    
    init(id: UUID = UUID(), name: String, source: AnimationSource, speed: CGFloat = 1.0, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.source = source
        self.speed = speed
        self.isBuiltIn = isBuiltIn
    }
    
    /// Get the effective transform config (override or default)
    func getTransformConfig() -> AnimationTransformConfig {
        let override = Defaults[.animationTransformOverrides][id.uuidString]
        if let override = override {
            print("📋 [CustomIdleAnimation] Found override for '\(name)': \(override)")
        } else {
            print("📋 [CustomIdleAnimation] No override for '\(name)', using default")
        }
        return override ?? .default
    }
}

struct AnimationTransformConfig: Codable, Hashable, Equatable, Defaults.Serializable {
    var scale: CGFloat = 1.0
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var cropWidth: CGFloat = 30
    var cropHeight: CGFloat = 20
    var rotation: CGFloat = 0
    var opacity: CGFloat = 1.0
    var paddingBottom: CGFloat = 0  // Allow adjustment to fill notch from bottom
    var expandWithAnimation: Bool = false  // Whether notch should expand horizontally with animation
    var loopMode: AnimationLoopMode = .loop  // Loop mode for animation
    
    static let `default` = AnimationTransformConfig()
}

enum AnimationLoopMode: String, Codable, CaseIterable {
    case loop = "Loop"
    case playOnce = "Play Once"
    case autoReverse = "Auto Reverse"
    
    var lottieLoopMode: LottieLoopMode {
        switch self {
        case .loop: return .loop
        case .playOnce: return .playOnce
        case .autoReverse: return .autoReverse
        }
    }
}

enum AnimationSource: Codable, Hashable, Equatable {
    case lottieFile(URL)        // Local file (in app support or bundle)
    case lottieURL(URL)         // Remote URL
    
    var displayType: String {
        switch self {
        case .lottieFile: return "Local"
        case .lottieURL: return "Remote"
        }
    }
}

// MARK: - Extension Authorization Models

enum ExtensionPermissionScope: String, CaseIterable, Codable, Defaults.Serializable {
    case liveActivities
    case lockScreenWidgets
    case notchExperiences
    case fileSharing

    var displayName: String {
        switch self {
        case .liveActivities: return String(localized: "Live Activities")
        case .lockScreenWidgets: return String(localized: "Lock Screen Widgets")
        case .notchExperiences: return String(localized: "Notch Experiences")
        case .fileSharing: return String(localized: "File Sharing")
        }
    }
}

enum ExtensionAuthorizationStatus: String, CaseIterable, Codable, Defaults.Serializable {
    case pending
    case authorized
    case denied
    case revoked

    var isActive: Bool {
        switch self {
        case .authorized: return true
        case .pending, .denied, .revoked: return false
        }
    }
}

struct ExtensionAuthorizationEntry: Codable, Defaults.Serializable, Identifiable, Hashable {
    let bundleIdentifier: String
    var appName: String
    var status: ExtensionAuthorizationStatus
    var allowedScopes: Set<ExtensionPermissionScope>
    var requestedAt: Date
    var grantedAt: Date?
    var lastActivityAt: Date?
    var lastDeniedReason: String?
    var notes: String?

    var id: String { bundleIdentifier }

    init(
        bundleIdentifier: String,
        appName: String,
        status: ExtensionAuthorizationStatus,
        allowedScopes: Set<ExtensionPermissionScope> = Set(ExtensionPermissionScope.allCases),
        requestedAt: Date = .now,
        grantedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        lastDeniedReason: String? = nil,
        notes: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.status = status
        self.allowedScopes = allowedScopes
        self.requestedAt = requestedAt
        self.grantedAt = grantedAt
        self.lastActivityAt = lastActivityAt
        self.lastDeniedReason = lastDeniedReason
        self.notes = notes
    }

    var isAuthorized: Bool { status.isActive }
}

struct ExtensionRateLimitRecord: Codable, Defaults.Serializable, Hashable, Identifiable {
    let bundleIdentifier: String
    var activityTimestamps: [Date]
    var widgetTimestamps: [Date]
    var notchExperienceTimestamps: [Date]

    var id: String { bundleIdentifier }

    init(
        bundleIdentifier: String,
        activityTimestamps: [Date] = [],
        widgetTimestamps: [Date] = [],
        notchExperienceTimestamps: [Date] = []
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.activityTimestamps = activityTimestamps
        self.widgetTimestamps = widgetTimestamps
        self.notchExperienceTimestamps = notchExperienceTimestamps
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case activityTimestamps
        case widgetTimestamps
        case notchExperienceTimestamps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        activityTimestamps = try container.decodeIfPresent([Date].self, forKey: .activityTimestamps) ?? []
        widgetTimestamps = try container.decodeIfPresent([Date].self, forKey: .widgetTimestamps) ?? []
        notchExperienceTimestamps = try container.decodeIfPresent([Date].self, forKey: .notchExperienceTimestamps) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(activityTimestamps, forKey: .activityTimestamps)
        try container.encode(widgetTimestamps, forKey: .widgetTimestamps)
        try container.encode(notchExperienceTimestamps, forKey: .notchExperienceTimestamps)
    }
}

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}

enum FantasticalViewStyle: String, CaseIterable, Codable, Defaults.Serializable {
    case mini = "mini"
    case calendar = "calendar"
    
    var displayName: String {
        switch self {
        case .mini: return String(localized: "Mini View")
        case .calendar: return String(localized: "Full Calendar")
        }
    }
}

enum ThirdPartyCalendarApp: String, CaseIterable, Codable, Defaults.Serializable, Identifiable {
    case fantastical = "fantastical"
    case notionCalendar = "notionCalendar"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .fantastical: return "Fantastical"
        case .notionCalendar: return "Notion Calendar"
        }
    }
    
    /// Bundle identifiers to try when looking up the app icon (first match wins).
    var bundleIdentifiers: [String] {
        switch self {
        case .fantastical: return ["com.flexibits.fantastical2.mac", "com.flexibits.fantastical"]
        case .notionCalendar: return ["com.cron.electron"]
        }
    }
    
    var fallbackIconName: String {
        switch self {
        case .fantastical: return "calendar.badge.clock"
        case .notionCalendar: return "calendar.badge.plus"
        }
    }
    
    var fallbackIconColor: Color {
        switch self {
        case .fantastical: return .red
        case .notionCalendar: return .blue
        }
    }
}

enum ClipboardDisplayMode: String, CaseIterable, Codable, Defaults.Serializable {
    case popover = "popover"     // Traditional popover attached to button
    case panel = "panel"         // Floating panel near notch
    case separateTab = "separateTab" // Separate tab in Dynamic Island (merges with Notes)
    case notchTab = "notchTab"   // Dedicated clipboard tab inside the notch (draggable items)

    var displayName: String {
        switch self {
        case .popover: return String(localized: "Popover")
        case .panel: return String(localized: "Panel")
        case .separateTab: return String(localized: "Separate Tab")
        case .notchTab: return String(localized: "Notch Tab")
        }
    }
    
    var description: String {
        switch self {
        case .popover: return "Shows clipboard as a dropdown attached to the clipboard button"
        case .panel: return "Shows clipboard in a floating panel near the notch"
        case .separateTab: return "Shows copied items in a separate tab within the Dynamic Island (merges with Notes if enabled)"
        case .notchTab: return "Shows copied items in a dedicated clipboard tab inside the notch; drag items straight out to other apps"
        }
    }
}

enum ScreenAssistantDisplayMode: String, CaseIterable, Codable, Defaults.Serializable {
    case popover = "popover"     // Traditional popover attached to button
    case panel = "panel"         // Floating panel near notch
    
    var displayName: String {
        switch self {
        case .popover: return String(localized: "Popover")
        case .panel: return String(localized: "Panel")
        }
    }
    
    var description: String {
        switch self {
        case .popover: return String(localized: "Shows screen assistant as a dropdown attached to the AI button")
        case .panel: return String(localized: "Shows screen assistant in a floating panel near the notch")
        }
    }
}

enum ColorPickerDisplayMode: String, CaseIterable, Codable, Defaults.Serializable {
    case popover = "popover"     // Traditional popover attached to button
    case panel = "panel"         // Floating panel near notch
    
    var displayName: String {
        switch self {
        case .popover: return String(localized: "Popover")
        case .panel: return String(localized: "Panel")
        }
    }
    
    var description: String {
        switch self {
        case .popover: return String(localized: "Shows color picker as a dropdown attached to the color picker button")
        case .panel: return String(localized: "Shows color picker in a floating panel near the notch")
        }
    }
}

enum ThirdPartyDDCProvider: String, CaseIterable, Codable, Defaults.Serializable, Identifiable {
    case betterDisplay
    case lunar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .betterDisplay:
            return "BetterDisplay"
        case .lunar:
            return "Lunar"
        }
    }
    
    /// Bundle identifiers to try when looking up the app icon.
    var bundleIdentifiers: [String] {
        switch self {
        case .betterDisplay: return ["pro.betterdisplay.BetterDisplay"]
        case .lunar: return ["fyi.lunar.Lunar"]
        }
    }
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    case nowPlayingOnly
    case never
}

// Define notification names at file scope
extension Notification.Name {
    static let mediaControllerChanged = Notification.Name("mediaControllerChanged")
}

// Media controller types for selection in settings
/// How the line being sung is picked out from the rest.
enum PinnedLyricContext: Int, CaseIterable, Identifiable, Defaults.Serializable {
    case current = 1
    case three = 3
    case five = 5

    var id: Int { rawValue }
    var localizedName: String {
        switch self {
        case .current: return String(localized: "Current")
        case .three: return String(localized: "3 lines")
        case .five: return String(localized: "5 lines")
        }
    }
}

enum LyricHighlightStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case sweep = "Sweep"
    case gradient = "Gradient"
    case solid = "Solid"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .sweep: return String(localized: "Sweep")
        case .gradient: return String(localized: "Gradient")
        case .solid: return String(localized: "Solid")
        }
    }

    var explanation: String {
        switch self {
        case .sweep:
            return String(localized: "The highlight travels across the line word by word, in reading order.")
        case .gradient:
            return String(localized: "The current line is lit by one fixed gradient that does not move, the way lyrics were marked before the sweep.")
        case .solid:
            return String(localized: "The current line is lit in one flat colour, with nothing crossing it.")
        }
    }
}

enum MediaControllerType: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying = "Now Playing"
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
    case youtubeMusic = "Youtube Music"
    case amazonMusic = "Amazon Music"
    case tidal = "TIDAL"
    case cider = "Cider"
    
    var id: String { self.rawValue }
    
    var localizedName: String {
        switch self {
        case .nowPlaying: return String(localized: "Now Playing")
        case .appleMusic: return String(localized: "Apple Music")
        case .spotify: return String(localized: "Spotify")
        case .youtubeMusic: return String(localized: "Youtube Music")
        case .amazonMusic: return String(localized: "Amazon Music")
        case .tidal: return String(localized: "TIDAL")
        case .cider: return String(localized: "Cider")
        }
    }

    // ZTAT-PATCH: Preserved from removed Onboarding/MusicControllerSelectionView.swift for Media Settings footer.
    var description: String {
        switch self {
        case .nowPlaying:
            return String(localized: "Works with most media apps, including browsers, to detect what's playing. Note: This may be removed in a future macOS version.")
        case .spotify:
            return String(localized: "Connects directly to the Spotify app.")
        case .appleMusic:
            return String(localized: "Connects directly to the Apple Music app.")
        case .youtubeMusic:
            return String(localized: "Requires a third-party client with API plugin enabled.")
        case .amazonMusic:
            return String(localized: "Uses macOS Now Playing when the Amazon Music app is the active media source. Playback controls follow the system Now Playing target. Scrubbing the timeline may not work if the Amazon Music app does not support remote seek.")
        case .tidal:
            return String(localized: "Uses macOS Now Playing when the TIDAL app is the active media source. Playback controls follow the system Now Playing target. Scrubbing, shuffle, or repeat may not work if TIDAL does not support the corresponding remote command.")
        case .cider:
            return String(localized: "Uses macOS Now Playing when Cider is the active media source. Playback controls follow the system Now Playing target.")
        }
    }
}

// Sneak peek styles for selection in settings
enum SneakPeekStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard = "Default"
    case inline = "Inline"
    
    var id: String { self.rawValue }
    
    var localizedName: String {
        switch self {
        case .standard: return String(localized: "Default")
        case .inline: return String(localized: "Inline")
        }
    }
}

enum LogLevel: Int, CaseIterable, Identifiable, Defaults.Serializable {
    case none = 0
    case error = 1
    case warning = 2
    case info = 3
    case debug = 4
    
    var id: Int { self.rawValue }
    
    var displayName: String {
        switch self {
        case .none: return "No Logging"
        case .error: return "Error"
        case .warning: return "Warning"
        case .info: return "Info"
        case .debug: return "Debug"
        }
    }
}

enum CapsLockIndicatorTintMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case green
    case accent
    case white

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .green:
            return String(localized: "Green")
        case .accent:
            return String(localized: "Accent")
        case .white:
            return String(localized: "White")
        }
    }

    var color: Color {
        switch self {
        case .green:
            return .green
        case .accent:
            return .accentColor
        case .white:
            return .white
        }
    }
}

enum ProgressBarStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case hierarchical = "Hierarchical"
    case gradient = "Gradient"
    case segmented = "Segmented"
    
    var id: String { self.rawValue }
}

enum BatteryNotificationStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            return String(localized: "Standard")
        case .compact:
            return String(localized: "Compact")
        }
    }
}

enum RecordingHoverStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case `default`
    case inline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default:
            return String(localized: "Default")
        case .inline:
            return String(localized: "Inline")
        }
    }
}

enum RecordingControlMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case indicatorOnly
    case withStopButton

    var id: String { rawValue }

    var title: String {
        switch self {
        case .indicatorOnly:
            return String(localized: "Indicator only")
        case .withStopButton:
            return String(localized: "With stop button")
        }
    }
}

enum MusicAuxiliaryControl: String, CaseIterable, Identifiable, Defaults.Serializable {
    case shuffle
    case repeatMode
    case mediaOutput
    case lyrics

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shuffle:
            return String(localized: "Shuffle")
        case .repeatMode:
            return String(localized: "Repeat")
        case .mediaOutput:
            return String(localized: "Media Output")
        case .lyrics:
            return String(localized: "Lyrics")
        }
    }

    var symbolName: String {
        switch self {
        case .shuffle:
            return "shuffle"
        case .repeatMode:
            return "repeat"
        case .mediaOutput:
            return "laptopcomputer"
        case .lyrics:
            return "quote.bubble"
        }
    }

    static func alternative(
        excluding control: MusicAuxiliaryControl,
        preferring candidate: MusicAuxiliaryControl? = nil
    ) -> MusicAuxiliaryControl {
        if let candidate, candidate != control {
            return candidate
        }

        return allCases.first { $0 != control } ?? .shuffle
    }
}

enum MusicSkipBehavior: String, CaseIterable, Identifiable, Defaults.Serializable {
    case track
    case tenSecond

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .track:
            return String(localized: "Track Skip")
        case .tenSecond:
            return String(localized: "±10 Seconds")
        }
    }

    var description: String {
        switch self {
        case .track:
            return String(localized: "Standard previous/next track controls")
        case .tenSecond:
            return String(localized: "Skip forward or backward by ten seconds")
        }
    }
}

enum TimerIconColorMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case adaptive = "Adaptive"
    case solid = "Solid"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .adaptive: return String(localized:"Adaptive gradient")
        case .solid: return String(localized:"Solid colour")
        }
    }
}

enum TimerProgressStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case bar = "Bar"
    case ring = "Ring"
    
    var id: String { rawValue }
    
    var localizedName: String {
        switch self {
        case .bar: return String(localized:"Bar")
        case .ring: return String(localized:"Ring")
        }
    }
}

enum CaffeinateDuration: String, CaseIterable, Identifiable, Defaults.Serializable {
    case indefinite = "indefinite"
    case fifteenMinutes = "fifteenMinutes"
    case thirtyMinutes = "thirtyMinutes"
    case oneHour = "oneHour"
    case twoHours = "twoHours"
    case fourHours = "fourHours"

    var id: String { rawValue }

    /// How long the session lasts, or `nil` when it runs until turned off.
    var seconds: TimeInterval? {
        switch self {
        case .indefinite: return nil
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twoHours: return 2 * 60 * 60
        case .fourHours: return 4 * 60 * 60
        }
    }

    var displayName: String {
        switch self {
        case .indefinite: return String(localized: "Until turned off")
        case .fifteenMinutes: return String(localized: "15 minutes")
        case .thirtyMinutes: return String(localized: "30 minutes")
        case .oneHour: return String(localized: "1 hour")
        case .twoHours: return String(localized: "2 hours")
        case .fourHours: return String(localized: "4 hours")
        }
    }
}

enum FocusMonitoringMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case withoutDevTools = "withoutDevTools"
    case useDevTools = "useDevTools"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .withoutDevTools:
            return "Use without DevTools"
        case .useDevTools:
            return "Use DevTools"
        }
    }
}

enum SiriResponsivenessMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case automatic
    case highPerformance
    case balanced
    case powerSaver

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .highPerformance: return String(localized: "High Performance")
        case .balanced: return String(localized: "Balanced")
        case .powerSaver: return String(localized: "Power Saver")
        }
    }

    var description: String {
        switch self {
        case .automatic: return String(localized: "Adapts based on power source and battery level.")
        case .highPerformance: return String(localized: "Ultra-fast detection (30Hz) for near-instant hiding.")
        case .balanced: return String(localized: "Standard detection (16Hz) for smooth responsiveness.")
        case .powerSaver: return String(localized: "Slower detection (4Hz) to maximize battery life.")
        }
    }
}

enum ReminderPresentationStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case ringCountdown = "Ring"
    case digital = "Digital"
    case minutes = "Minutes"

    var id: String { rawValue }

    var displayName: String {
        switch self {
            case .ringCountdown:
                return String(localized: "Ring")
            case .digital:
                return String(localized: "Digital")
            case .minutes:
                return String(localized: "Minutes")
        }
    }
}

// AI Model types for screen assistant
enum AIModelProvider: String, CaseIterable, Identifiable, Defaults.Serializable {
    case gemini = "Gemini"
    case openai = "OpenAI GPT"
    case claude = "Claude"
    case local = "Local Model"
    case groq = "Groq"
    
    var id: String { self.rawValue }
    
    var displayName: String {
        return self.rawValue
    }
    
    var description: String {
        switch self {
        case .gemini: return String(localized: "Google's Gemini AI with multimodal capabilities")
        case .openai: return String(localized: "OpenAI's GPT models with advanced reasoning")
        case .claude: return String(localized: "Anthropic's Claude with strong analytical skills")
        case .local: return String(localized: "Local AI model (Ollama or similar)")
        case .groq: return String(localized: "Groq's fast inference for OpenAI-compatible models")
        }
    }
    
    var supportedModels: [AIModel] {
        switch self {
        case .gemini:
            return [
                // Gemini 2.5 Models (Latest)
                AIModel(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", supportsThinking: true),
                AIModel(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", supportsThinking: true),
                AIModel(id: "gemini-2.5-flash-lite", name: "Gemini 2.5 Flash-Lite", supportsThinking: false),
                AIModel(id: "gemini-2.5-flash-live", name: "Gemini 2.5 Flash Live", supportsThinking: false),
                AIModel(id: "gemini-2.5-flash-native-audio", name: "Gemini 2.5 Flash Native Audio", supportsThinking: true),
                
                // Gemini 2.0 Models
                AIModel(id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", supportsThinking: false),
                AIModel(id: "gemini-2.0-flash-lite", name: "Gemini 2.0 Flash-Lite", supportsThinking: false),
                AIModel(id: "gemini-2.0-flash-live", name: "Gemini 2.0 Flash Live", supportsThinking: false),
                
                // Legacy 1.5 Models (for compatibility)
                AIModel(id: "gemini-1.5-pro", name: "Gemini 1.5 Pro", supportsThinking: false),
                AIModel(id: "gemini-1.5-flash", name: "Gemini 1.5 Flash", supportsThinking: false)
            ]
        case .openai:
            return [
                AIModel(id: "gpt-4o", name: "GPT-4o", supportsThinking: false),
                AIModel(id: "gpt-4o-mini", name: "GPT-4o Mini", supportsThinking: false),
                AIModel(id: "o1-preview", name: "o1 Preview", supportsThinking: true),
                AIModel(id: "o1-mini", name: "o1 Mini", supportsThinking: true)
            ]
        case .claude:
            return [
                AIModel(id: "claude-3-5-sonnet", name: "Claude 3.5 Sonnet", supportsThinking: false),
                AIModel(id: "claude-3-haiku", name: "Claude 3 Haiku", supportsThinking: false)
            ]
        case .local:
            return [
                AIModel(id: "llama3.2", name: "Llama 3.2", supportsThinking: false),
                AIModel(id: "qwen2.5", name: "Qwen 2.5", supportsThinking: false)
            ]
        case .groq:
            return [
                AIModel(id: "llama-3.3-70b-versatile", name: "Llama 3.3 70B Versatile", supportsThinking: false),
                AIModel(id: "llama-3.1-8b-instant", name: "Llama 3.1 8B Instant", supportsThinking: false),
                AIModel(id: "qwen-qwq-32b", name: "Qwen QWQ 32B", supportsThinking: false),
                AIModel(id: "mixtral-8x7b-32768", name: "Mixtral 8x7B", supportsThinking: false)
            ]
        }
    }
}

struct AIModel: Codable, Identifiable, Defaults.Serializable {
    let id: String
    let name: String
    let supportsThinking: Bool
    
    var displayName: String {
        return name + (supportsThinking ? " (Thinking)" : "")
    }
}

struct NoteItem: Codable, Identifiable, Defaults.Serializable, Hashable {
    var id: UUID = UUID()
    var title: String
    var content: String
    var creationDate: Date
    var modificationDate: Date
    var colorIndex: Int // 0: Yellow, 1: Blue, 2: Red, 3: Green
    var isPinned: Bool = false
    var imageFileName: String? = nil // Store filename instead of raw data
    var appleNotesId: String? = nil
    
    // Internal property for migration
    private enum CodingKeys: String, CodingKey {
        case id, title, content, creationDate, modificationDate, colorIndex, isPinned, imageFileName, imageData, appleNotesId
    }
    
    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        creationDate: Date,
        modificationDate: Date? = nil,
        colorIndex: Int,
        isPinned: Bool = false,
        imageFileName: String? = nil,
        appleNotesId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.creationDate = creationDate
        self.modificationDate = modificationDate ?? creationDate
        self.colorIndex = colorIndex
        self.isPinned = isPinned
        self.imageFileName = imageFileName
        self.appleNotesId = appleNotesId
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        creationDate = try container.decode(Date.self, forKey: .creationDate)
        modificationDate = try container.decodeIfPresent(Date.self, forKey: .modificationDate) ?? creationDate
        colorIndex = try container.decode(Int.self, forKey: .colorIndex)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        appleNotesId = try container.decodeIfPresent(String.self, forKey: .appleNotesId)
        
        // Migration logic: if imageData exists but imageFileName doesn't, save it to disk
        if let data = try container.decodeIfPresent(Data.self, forKey: .imageData) {
            let fileName = "note_image_\(id.uuidString).png"
            let fileURL = NoteItem.noteImageDataDirectory.appendingPathComponent(fileName)
            try? data.write(to: fileURL)
            imageFileName = fileName
        } else {
            imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(creationDate, forKey: .creationDate)
        try container.encode(modificationDate, forKey: .modificationDate)
        try container.encode(colorIndex, forKey: .colorIndex)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(imageFileName, forKey: .imageFileName)
        try container.encodeIfPresent(appleNotesId, forKey: .appleNotesId)
    }
    
    static let colors: [Color] = [.yellow, .blue, .red, .green, .purple, .orange]
    
    // Directory for storing note image files
    static let noteImageDataDirectory: URL = {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let notesDir = documentsPath.appendingPathComponent("NoteImages")
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        return notesDir
    }()
    
    var color: Color {
        if colorIndex >= 0 && colorIndex < NoteItem.colors.count {
            return NoteItem.colors[colorIndex]
        }
        return .yellow
    }
    
    // Helper to get image data from file
    func getImageData() -> Data? {
        guard let fileName = imageFileName else { return nil }
        let fileURL = NoteItem.noteImageDataDirectory.appendingPathComponent(fileName)
        return try? Data(contentsOf: fileURL)
    }
}

enum ColorExtractionMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case legacy, vibrant
    var id: Self { self }
}

enum LockScreenLiveActivityIconStyle: String, Defaults.Serializable {
    case lock
    case fingerprint
    case both

    var showsLock: Bool { self == .lock || self == .both }
    var showsFingerprint: Bool { self == .fingerprint || self == .both }
}

extension Defaults.Keys {
        // MARK: General
    // ZTAT-PATCH: Master enable/disable toggle for the embedded ZtatIsland engine.
    static let enableDynamicIsland = Key<Bool>("enableDynamicIsland", default: true, suite: islandDefaults)
    static let logLevel = Key<LogLevel>("logLevel", default: .none, suite: islandDefaults)
    static let menubarIcon = Key<Bool>("menubarIcon", default: false, suite: islandDefaults)
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false, suite: islandDefaults)
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: true, suite: islandDefaults)
    static let releaseName = Key<String>("releaseName", default: "Kaafu", suite: islandDefaults)
    static let hideDynamicIslandFromScreenCapture = Key<Bool>("hideDynamicIslandFromScreenCapture", default: false, suite: islandDefaults)
    
        // MARK: Behavior
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3, suite: islandDefaults)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true, suite: islandDefaults)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true, suite: islandDefaults)
	static let extendHoverArea = Key<Bool>("extendHoverArea", default: false, suite: islandDefaults)
    static let externalDisplayStyle = Key<ExternalDisplayStyle>(
        "externalDisplayStyle",
        default: .notch
    , suite: islandDefaults)
    static let hideNonNotchUntilHover = Key<Bool>("hideNonNotchUntilHover", default: false, suite: islandDefaults)
    static let notchHeightMode = Key<WindowHeightMode>(
        "notchHeightMode",
        default: WindowHeightMode.matchRealNotchSize
    , suite: islandDefaults)
    static let nonNotchHeightMode = Key<WindowHeightMode>(
        "nonNotchHeightMode",
        default: WindowHeightMode.matchMenuBar
    , suite: islandDefaults)
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32, suite: islandDefaults)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32, suite: islandDefaults)
    static let openNotchWidth = Key<CGFloat>("openNotchWidth", default: 640, suite: islandDefaults)
    static let closedNotchWidth = Key<CGFloat>("closedNotchWidth", default: 150, suite: islandDefaults)
    static let customizePhysicalNotchWidth = Key<Bool>("customizePhysicalNotchWidth", default: false, suite: islandDefaults)
        //static let openLastTabByDefault = Key<Bool>("openLastTabByDefault", default: false, suite: islandDefaults)
    
        // MARK: Appearance
    static let showEmojis = Key<Bool>("showEmojis", default: false, suite: islandDefaults)
        //static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true, suite: islandDefaults)
    static let showMirror = Key<Bool>("showMirror", default: false, suite: islandDefaults)
    static let mirrorShape = Key<MirrorShapeEnum>("mirrorShape", default: MirrorShapeEnum.rectangle, suite: islandDefaults)
    static let selectedCameraID = Key<String>("selectedCameraID", default: "", suite: islandDefaults)
    static let settingsIconInNotch = Key<Bool>("settingsIconInNotch", default: true, suite: islandDefaults)
    static let lightingEffect = Key<Bool>("lightingEffect", default: true, suite: islandDefaults)
    static let accentColor = Key<Color>("accentColor", default: Color.blue, suite: islandDefaults)
    static let enableShadow = Key<Bool>("enableShadow", default: true, suite: islandDefaults)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true, suite: islandDefaults)
    static let useModernCloseAnimation = Key<Bool>("useModernCloseAnimation", default: true, suite: islandDefaults)
    static let showNotHumanFace = Key<Bool>("showNotHumanFace", default: false, suite: islandDefaults)
    static let customIdleAnimations = Key<[CustomIdleAnimation]>("customIdleAnimations", default: [], suite: islandDefaults)
    static let selectedIdleAnimation = Key<CustomIdleAnimation?>("selectedIdleAnimation", default: nil, suite: islandDefaults)
    static let animationTransformOverrides = Key<[String: AnimationTransformConfig]>("animationTransformOverrides", default: [:], suite: islandDefaults)
    static let tileShowLabels = Key<Bool>("tileShowLabels", default: false, suite: islandDefaults)
    static let showCalendar = Key<Bool>("showCalendar", default: true, suite: islandDefaults)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true, suite: islandDefaults)
    static let hideAllDayEvents = Key<Bool>("hideAllDayEvents", default: false, suite: islandDefaults)
    static let sliderColor = Key<SliderColorEnum>(
        "sliderUseAlbumArtColor",
        default: SliderColorEnum.white
    , suite: islandDefaults)
    static let playerColorTinting = Key<Bool>("playerColorTinting", default: true, suite: islandDefaults)
    static let useMusicVisualizer = Key<Bool>("useMusicVisualizer", default: true, suite: islandDefaults)
    static let visualizerBarCount = Key<Int>("visualizerBarCount", default: 4, suite: islandDefaults)
    static let enableWaveformScrubber = Key<Bool>("enableWaveformScrubber", default: true, suite: islandDefaults)
    static let colorExtractionMode = Key<ColorExtractionMode>("colorExtractionMode", default: .vibrant, suite: islandDefaults)
    static let customVisualizers = Key<[CustomVisualizer]>("customVisualizers", default: [], suite: islandDefaults)
    static let selectedVisualizer = Key<CustomVisualizer?>("selectedVisualizer", default: nil, suite: islandDefaults)
    static let customAppIcons = Key<[CustomAppIcon]>("customAppIcons", default: [], suite: islandDefaults)
    static let selectedAppIconID = Key<String?>("selectedAppIconID", default: nil, suite: islandDefaults)
    
        // MARK: Gestures
    static let enableGestures = Key<Bool>("enableGestures", default: true, suite: islandDefaults)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: true, suite: islandDefaults)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200.0, suite: islandDefaults)
    static let enableHorizontalMusicGestures = Key<Bool>("enableHorizontalMusicGestures", default: true, suite: islandDefaults)
    static let musicGestureBehavior = Key<MusicSkipBehavior>("musicGestureBehavior", default: .track, suite: islandDefaults)
    static let reverseSwipeGestures = Key<Bool>("reverseSwipeGestures", default: false, suite: islandDefaults)
    static let reverseScrollGestures = Key<Bool>("reverseScrollGestures", default: false, suite: islandDefaults)
    
        // MARK: Media playback
    static let coloredSpectrogram = Key<Bool>("coloredSpectrogram", default: true, suite: islandDefaults)
    static let enableRealTimeWaveform = Key<Bool>("enableRealTimeWaveform", default: false, suite: islandDefaults)
    static let enableSneakPeek = Key<Bool>("enableSneakPeek", default: false, suite: islandDefaults)
    static let sneakPeekStyles = Key<SneakPeekStyle>("sneakPeekStyles", default: .standard, suite: islandDefaults)
    static let showSneakPeekOnTrackChange = Key<Bool>("showSneakPeekOnTrackChange", default: true, suite: islandDefaults)
    static let enableFullscreenMediaDetection = Key<Bool>("enableFullscreenMediaDetection", default: true, suite: islandDefaults)
    static let parallaxEffectIntensity = Key<Double>("parallaxEffectIntensity", default: 6.0, suite: islandDefaults)
    static let waitInterval = Key<Double>("waitInterval", default: 3, suite: islandDefaults)
    static let showShuffleAndRepeat = Key<Bool>("showShuffleAndRepeat", default: true, suite: islandDefaults)
    static let showMediaOutputControl = Key<Bool>("showMediaOutputControl", default: true, suite: islandDefaults)
    /// Whether the lock screen panel keeps a volume slider under the transport
    /// row, rather than leaving volume behind the output button.
    ///
    /// Off by default and named after the setting it copies: iOS puts "Always
    /// Show Volume Control" in Accessibility rather than showing the slider to
    /// everybody, because a Lock Screen that is mostly artwork is the point for
    /// most people and a permanent slider is a preference, not an improvement.
    static let alwaysShowLockScreenVolume = Key<Bool>("alwaysShowLockScreenVolume", default: false, suite: islandDefaults)
    static let musicAuxLeftControl = Key<MusicAuxiliaryControl>("musicAuxLeftControl", default: .shuffle, suite: islandDefaults)
    static let musicAuxRightControl = Key<MusicAuxiliaryControl>("musicAuxRightControl", default: .repeatMode, suite: islandDefaults)
    static let didMigrateMusicAuxControls = Key<Bool>("didMigrateMusicAuxControls", default: false, suite: islandDefaults)
    static let musicControlSlots = Key<[MusicControlButton]>("musicControlSlots", default: MusicControlButton.defaultLayout, suite: islandDefaults)
    static let didMigrateMusicControlSlots = Key<Bool>("didMigrateMusicControlSlots", default: false, suite: islandDefaults)
    static let musicSkipBehavior = Key<MusicSkipBehavior>("musicSkipBehavior", default: .track, suite: islandDefaults)
    static let musicControlWindowEnabled = Key<Bool>("musicControlWindowEnabled", default: false, suite: islandDefaults)
    static let showStandardMediaControls = Key<Bool>("showStandardMediaControls", default: true, suite: islandDefaults)
    static let autoHideInactiveNotchMediaPlayer = Key<Bool>("autoHideInactiveNotchMediaPlayer", default: true, suite: islandDefaults)
    static let cachedMusicLiveActivityPreference = Key<Bool?>("cachedMusicLiveActivityPreference", default: nil, suite: islandDefaults)
    static let cachedLockScreenMediaWidgetPreference = Key<Bool?>("cachedLockScreenMediaWidgetPreference", default: nil, suite: islandDefaults)
    static let cachedMusicControlWindowPreference = Key<Bool?>("cachedMusicControlWindowPreference", default: nil, suite: islandDefaults)
    // Enable lock screen media widget (shows the standalone panel when screen is locked)
    static let enableLockScreenMediaWidget = Key<Bool>("enableLockScreenMediaWidget", default: true, suite: islandDefaults)
    static let enableLockScreenWeatherWidget = Key<Bool>("enableLockScreenWeatherWidget", default: true, suite: islandDefaults)
    static let enableLockScreenFocusWidget = Key<Bool>("enableLockScreenFocusWidget", default: true, suite: islandDefaults)
    static let siriResponsivenessMode = Key<SiriResponsivenessMode>("siriResponsivenessMode", default: .automatic, suite: islandDefaults)
    static let enableLockScreenReminderWidget = Key<Bool>("enableLockScreenReminderWidget", default: true, suite: islandDefaults)
    static let enableLockScreenTimerWidget = Key<Bool>("enableLockScreenTimerWidget", default: true, suite: islandDefaults)
    static let lockScreenWeatherRefreshInterval = Key<TimeInterval>("lockScreenWeatherRefreshInterval", default: 30 * 60, suite: islandDefaults)
    static let lockScreenWeatherShowsLocation = Key<Bool>("lockScreenWeatherShowsLocation", default: true, suite: islandDefaults)
    static let lockScreenWeatherShowsSunrise = Key<Bool>("lockScreenWeatherShowsSunrise", default: true, suite: islandDefaults)
    static let lockScreenWeatherWidgetStyle = Key<LockScreenWeatherWidgetStyle>("lockScreenWeatherWidgetStyle", default: .inline, suite: islandDefaults)
    static let lockScreenWeatherTemperatureUnit = Key<LockScreenWeatherTemperatureUnit>("lockScreenWeatherTemperatureUnit", default: .matchingSystemPreference, suite: islandDefaults)
    static let lockScreenWeatherShowsAQI = Key<Bool>("lockScreenWeatherShowsAQI", default: true, suite: islandDefaults)
    static let lockScreenWeatherAQIScale = Key<LockScreenWeatherAirQualityScale>("lockScreenWeatherAQIScale", default: .us, suite: islandDefaults)
    static let lockScreenWeatherUsesGaugeTint = Key<Bool>("lockScreenWeatherUsesGaugeTint", default: false, suite: islandDefaults)
    static let lockScreenWeatherProviderSource = Key<LockScreenWeatherProviderSource>("lockScreenWeatherProviderSource", default: .openMeteo, suite: islandDefaults)
    static let lockScreenWeatherVerticalOffset = Key<Double>("lockScreenWeatherVerticalOffset", default: 0, suite: islandDefaults)
    static let lockScreenMusicVerticalOffset = Key<Double>("lockScreenMusicVerticalOffset", default: 0, suite: islandDefaults)
    static let lockScreenMusicPanelWidth = Key<Double>(
        "lockScreenMusicPanelWidth",
        default: Double(LockScreenMusicPanel.defaultCollapsedWidth)
    , suite: islandDefaults)
    static let lockScreenMusicAlbumParallaxEnabled = Key<Bool>("lockScreenMusicAlbumParallaxEnabled", default: false, suite: islandDefaults)
    static let lockScreenTimerVerticalOffset = Key<Double>("lockScreenTimerVerticalOffset", default: 0, suite: islandDefaults)
    static let lockScreenTimerWidgetWidth = Key<Double>("lockScreenTimerWidgetWidth", default: 350, suite: islandDefaults)
    static let lockScreenWidgetAppearance = Key<LockScreenWidgetAppearance>("lockScreenWidgetAppearance", default: .dark, suite: islandDefaults)
    static let lockScreenGlassStyle = Key<LockScreenGlassStyle>("lockScreenGlassStyle", default: .liquid, suite: islandDefaults)
    static let lockScreenGlassCustomizationMode = Key<LockScreenGlassCustomizationMode>(
        "lockScreenGlassCustomizationMode",
        default: .standard
    , suite: islandDefaults)
    static let lockScreenTimerGlassStyle = Key<LockScreenGlassStyle>("lockScreenTimerGlassStyle", default: .frosted, suite: islandDefaults)
    static let lockScreenTimerGlassCustomizationMode = Key<LockScreenGlassCustomizationMode>(
        "lockScreenTimerGlassCustomizationMode",
        default: .standard
    , suite: islandDefaults)
    static let lockScreenMusicLiquidGlassVariant = Key<LiquidGlassVariant>(
        "lockScreenMusicLiquidGlassVariant",
        default: .defaultVariant
    , suite: islandDefaults)
    static let lockScreenTimerLiquidGlassVariant = Key<LiquidGlassVariant>(
        "lockScreenTimerLiquidGlassVariant",
        default: .defaultVariant
    , suite: islandDefaults)
    static let lockScreenShowAppIcon = Key<Bool>("lockScreenShowAppIcon", default: false, suite: islandDefaults)
    static let lockScreenPanelShowsBorder = Key<Bool>("lockScreenPanelShowsBorder", default: false, suite: islandDefaults)
    static let lockScreenMusicUsesEnhancedLiquidBorder = Key<Bool>(
        "lockScreenMusicUsesEnhancedLiquidBorder",
        default: true
    , suite: islandDefaults)
    static let lockScreenPanelUsesBlur = Key<Bool>("lockScreenPanelUsesBlur", default: true, suite: islandDefaults)
    static let lockScreenMusicMergedAirPlayOutput = Key<Bool>("lockScreenMusicMergedAirPlayOutput", default: true, suite: islandDefaults)
    static let lockScreenMusicFullscreenArtworkEnabled = Key<Bool>("lockScreenMusicFullscreenArtworkEnabled", default: true, suite: islandDefaults)
    static let lockScreenKeepAlbumArtVisibleDuringFullscreenArtwork = Key<Bool>("lockScreenKeepAlbumArtVisibleDuringFullscreenArtwork", default: false, suite: islandDefaults)
    static let lockScreenMusicFullscreenVideoArtwork = Key<Bool>("lockScreenMusicFullscreenVideoArtwork", default: false, suite: islandDefaults)
    static let lockScreenUseArtworkLayoutOverFullscreenCanvas = Key<Bool>("lockScreenShowCenteredAlbumArtOverFullscreenCanvas", default: true, suite: islandDefaults)
    static let lockScreenTimerWidgetUsesBlur = Key<Bool>("lockScreenTimerWidgetUsesBlur", default: false, suite: islandDefaults)
    static let lockScreenReminderChipStyle = Key<LockScreenReminderChipStyle>("lockScreenReminderChipStyle", default: .eventColor, suite: islandDefaults)
    static let lockScreenReminderWidgetHorizontalAlignment = Key<String>("lockScreenReminderWidgetHorizontalAlignment", default: "center", suite: islandDefaults)
    static let lockScreenReminderWidgetVerticalOffset = Key<Double>("lockScreenReminderWidgetVerticalOffset", default: 0, suite: islandDefaults)
    static let lockScreenShowCalendarEvent = Key<Bool>("lockScreenShowCalendarEvent", default: true, suite: islandDefaults)
    static let lockScreenCalendarEventLookaheadWindow = Key<String>("lockScreenCalendarEventLookaheadWindow", default: "3h", suite: islandDefaults)
    static let lockScreenCalendarSelectionMode = Key<String>("lockScreenCalendarSelectionMode", default: "all", suite: islandDefaults)
    static let lockScreenSelectedCalendarIDs = Key<Set<String>>("lockScreenSelectedCalendarIDs", default: [])
    static let lockScreenShowCalendarCountdown = Key<Bool>("lockScreenShowCalendarCountdown", default: true, suite: islandDefaults)
    static let lockScreenShowCalendarEventEntireDuration = Key<Bool>("lockScreenShowCalendarEventEntireDuration", default: true, suite: islandDefaults)
    static let lockScreenShowCalendarEventAfterStartEnabled = Key<Bool>("lockScreenShowCalendarEventAfterStartEnabled", default: false, suite: islandDefaults)
    static let lockScreenShowCalendarEventAfterStartWindow = Key<String>("lockScreenShowCalendarEventAfterStartWindow", default: "5m", suite: islandDefaults)
    static let lockScreenShowCalendarTimeRemaining = Key<Bool>("lockScreenShowCalendarTimeRemaining", default: true, suite: islandDefaults)
    static let lockScreenShowCalendarStartTimeAfterBegins = Key<Bool>("lockScreenShowCalendarStartTimeAfterBegins", default: true, suite: islandDefaults)
    static let lockScreenWeatherWidgetRowOrder = Key<String>("lockScreenWeatherWidgetRowOrder", default: "weather_calendar_focus", suite: islandDefaults)
    
    // MARK: Third-party Calendar Integration
    static let enableThirdPartyCalendarApp = Key<Bool>("enableThirdPartyCalendarApp", default: false, suite: islandDefaults)
    static let selectedCalendarApp = Key<ThirdPartyCalendarApp>("selectedCalendarApp", default: .fantastical, suite: islandDefaults)
    static let fantasticalDefaultView = Key<FantasticalViewStyle>("fantasticalDefaultView", default: .mini, suite: islandDefaults)
    
        // MARK: Battery
    static let showPowerStatusNotifications = Key<Bool>("showPowerStatusNotifications", default: true, suite: islandDefaults)
    static let showBatteryIndicator = Key<Bool>("showBatteryIndicator", default: BatteryActivityManager.shared.hasBattery(), suite: islandDefaults)
    static let showBatteryPercentage = Key<Bool>("showBatteryPercentage", default: true, suite: islandDefaults)
    static let showBatteryPercentInside = Key<Bool>("showBatteryPercentInside", default: true, suite: islandDefaults)
    static let showMinimalisticBatteryIndicator = Key<Bool>("showMinimalisticBatteryIndicator", default: true, suite: islandDefaults)
    static let showPowerStatusIcons = Key<Bool>("showPowerStatusIcons", default: true, suite: islandDefaults)
    static let playLowBatteryAlertSound = Key<Bool>("playLowBatteryAlertSound", default: true, suite: islandDefaults)
    static let showChargingBatteryHUD = Key<Bool>("showChargingBatteryHUD", default: true, suite: islandDefaults)
    static let showLowBatteryHUD = Key<Bool>("showLowBatteryHUD", default: true, suite: islandDefaults)
    static let showFullBatteryHUD = Key<Bool>("showFullBatteryHUD", default: true, suite: islandDefaults)
    static let chargingBatteryHUDDuration = Key<Int>("chargingBatteryHUDDuration", default: 3, suite: islandDefaults)
    static let lowBatteryHUDDuration = Key<Int>("lowBatteryHUDDuration", default: 3, suite: islandDefaults)
    static let fullBatteryHUDDuration = Key<Int>("fullBatteryHUDDuration", default: 3, suite: islandDefaults)
    static let lowBatteryHUDThreshold = Key<Int>("lowBatteryHUDThreshold", default: 20, suite: islandDefaults)
    static let fullBatteryHUDThreshold = Key<Int>("fullBatteryHUDThreshold", default: 100, suite: islandDefaults)
    static let lowBatteryHUDStyle = Key<BatteryNotificationStyle>("lowBatteryHUDStyle", default: .standard, suite: islandDefaults)
    static let fullBatteryHUDStyle = Key<BatteryNotificationStyle>("fullBatteryHUDStyle", default: .standard, suite: islandDefaults)

    static let lockScreenBatteryShowsBatteryGauge = Key<Bool>(
        "lockScreenWeatherShowsBatteryGauge",
        default: BatteryActivityManager.shared.hasBattery()
    , suite: islandDefaults)
    static let lockScreenBatteryUsesLaptopSymbol = Key<Bool>("lockScreenWeatherBatteryUsesLaptopSymbol", default: true, suite: islandDefaults)
    static let lockScreenBatteryShowsCharging = Key<Bool>("lockScreenWeatherShowsCharging", default: true, suite: islandDefaults)
    static let lockScreenBatteryShowsChargingPercentage = Key<Bool>("lockScreenWeatherShowsChargingPercentage", default: true, suite: islandDefaults)
    static let lockScreenBatteryShowsBluetooth = Key<Bool>("lockScreenWeatherShowsBluetooth", default: true, suite: islandDefaults)
    
        // MARK: Downloads
    static let enableDownloadListener = Key<Bool>("enableDownloadListener", default: true, suite: islandDefaults)
    static let enableSafariDownloads = Key<Bool>("enableSafariDownloads", default: true, suite: islandDefaults)
    static let selectedDownloadIndicatorStyle = Key<DownloadIndicatorStyle>("selectedDownloadIndicatorStyle", default: DownloadIndicatorStyle.progress, suite: islandDefaults)
    static let showDownloadSpeed = Key<Bool>("showDownloadSpeed", default: false, suite: islandDefaults)
    static let selectedDownloadIconStyle = Key<DownloadIconStyle>("selectedDownloadIconStyle", default: DownloadIconStyle.onlyAppIcon, suite: islandDefaults)
    
        // MARK: HUD
    static let inlineHUD = Key<Bool>("inlineHUD", default: true, suite: islandDefaults)
    static let progressBarStyle = Key<ProgressBarStyle>("progressBarStyle", default: .hierarchical, suite: islandDefaults)
    // Legacy support - keeping for backward compatibility
    static let enableGradient = Key<Bool>("enableGradient", default: false, suite: islandDefaults)
    static let systemEventIndicatorShadow = Key<Bool>("systemEventIndicatorShadow", default: false, suite: islandDefaults)
    static let systemEventIndicatorUseAccent = Key<Bool>("systemEventIndicatorUseAccent", default: false, suite: islandDefaults)
    static let showProgressPercentages = Key<Bool>("showProgressPercentages", default: true, suite: islandDefaults)
    
        // MARK: Shelf
    static let dynamicShelf = Key<Bool>("dynamicShelf", default: true, suite: islandDefaults)
    static let openShelfByDefault = Key<Bool>("openShelfByDefault", default: true, suite: islandDefaults)
        static let quickShareProvider = Key<String>("quickShareProvider", default: "AirDrop", suite: islandDefaults)
        static let localSendSelectedDeviceID = Key<String>("localSendSelectedDeviceID", default: "", suite: islandDefaults)
        static let localSendDevicePickerGlassMode = Key<LockScreenGlassCustomizationMode>("localSendDevicePickerGlassMode", default: .standard, suite: islandDefaults)
        static let localSendDevicePickerLiquidGlassVariant = Key<LiquidGlassVariant>("localSendDevicePickerLiquidGlassVariant", default: .v11, suite: islandDefaults)
        static let copyOnDrag = Key<Bool>("copyOnDrag", default: false, suite: islandDefaults)
        // Off by default: offering `.move` to another app lets Finder move the
        // original out from under the user when the destination is on the same
        // volume, which reads as data loss.
        static let allowMoveOnDrag = Key<Bool>("allowMoveOnDrag", default: false, suite: islandDefaults)
        static let autoRemoveShelfItems = Key<Bool>("autoRemoveShelfItems", default: false, suite: islandDefaults)
        static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true, suite: islandDefaults)
    
        // MARK: Calendar
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all, suite: islandDefaults)
        static let showFullEventTitles = Key<Bool>("showFullEventTitles", default: false, suite: islandDefaults)
        static let autoScrollToNextEvent = Key<Bool>("autoScrollToNextEvent", default: true, suite: islandDefaults)
    
        // MARK: Fullscreen Media Detection
    static let alwaysHideInFullscreen = Key<Bool>("alwaysHideInFullscreen", default: false, suite: islandDefaults)
    
    static let hideNotchOption = Key<HideNotchOption>("hideNotchOption", default: .nowPlayingOnly, suite: islandDefaults)
    
    // MARK: Wobble Animation
    static let enableWobbleAnimation = Key<Bool>("enableWobbleAnimation", default: false, suite: islandDefaults)
    
    // MARK: Media Controller
    static let mediaController = Key<MediaControllerType>("mediaController", default: defaultMediaController, suite: islandDefaults)
    static let spotifySPDCCookie = Key<String>("spotifySPDCCookie", default: "", suite: islandDefaults)
    static let spotifyAuthAccessToken = Key<String>("spotifyAuthAccessToken", default: "", suite: islandDefaults)
    static let spotifyAuthAccessTokenExpiration = Key<Double>("spotifyAuthAccessTokenExpiration", default: 0, suite: islandDefaults)
    static let spotifyAuthLastValidatedAt = Key<Double>("spotifyAuthLastValidatedAt", default: 0, suite: islandDefaults)
    static let spotifyLibraryClientID = Key<String>("spotifyLibraryClientID", default: "", suite: islandDefaults)

    /// Token for Cider's external-application API, from
    /// Settings > Connectivity > Manage External Application Access in Cider.
    /// Empty is a valid setting: Cider can also run that API with
    /// authentication switched off, and then no header is wanted at all.
    /// Superseded by `CiderTokenStore`, which keeps the token in the Keychain.
    /// Kept only so an existing value can be migrated out of the preferences
    /// plist on first launch; nothing reads it to make a request.
    /// Named `legacy…` so nothing new reaches for it by the old name; the
    /// stored key string is unchanged so existing values still migrate.
    /// A `@available(*, deprecated)` attribute would have been the obvious
    /// alternative, but it fires on `CiderTokenStore` -- the one place that is
    /// supposed to read this -- and a warning at the sanctioned use site is
    /// worse than none.
    static let legacyCiderAPIToken = Key<String>("ciderAPIToken", default: "", suite: islandDefaults)
    // The OAuth token pair lives in the Keychain (see KeychainSpotifyTokenStore);
    // these two keys remain only for the one-time migration of early builds.
    static let spotifyLibraryAccessToken = Key<String>("spotifyLibraryAccessToken", default: "", suite: islandDefaults)
    static let spotifyLibraryRefreshToken = Key<String>("spotifyLibraryRefreshToken", default: "", suite: islandDefaults)
    static let spotifyLibraryTokenExpiration = Key<Double>("spotifyLibraryTokenExpiration", default: 0, suite: islandDefaults)
    
    // MARK: Bluetooth Audio Devices
    static let showBluetoothDeviceConnections = Key<Bool>("showBluetoothDeviceConnections", default: true, suite: islandDefaults)
    static let useColorCodedBatteryDisplay = Key<Bool>("useColorCodedBatteryDisplay", default: true, suite: islandDefaults)
    static let useColorCodedVolumeDisplay = Key<Bool>("useColorCodedVolumeDisplay", default: true, suite: islandDefaults)
    static let useSmoothColorGradient = Key<Bool>("useSmoothColorGradient", default: true, suite: islandDefaults)
    static let useCircularBluetoothBatteryIndicator = Key<Bool>("useCircularBluetoothBatteryIndicator", default: true, suite: islandDefaults)
    static let showBluetoothBatteryPercentageText = Key<Bool>("showBluetoothBatteryPercentageText", default: false, suite: islandDefaults)
    static let showBluetoothDeviceNameMarquee = Key<Bool>("showBluetoothDeviceNameMarquee", default: false, suite: islandDefaults)
    static let useBluetoothHUD3DIcon = Key<Bool>("useBluetoothHUD3DIcon", default: true, suite: islandDefaults)
    static let showAirPodsListeningModeChanges = Key<Bool>("showAirPodsListeningModeChanges", default: true, suite: islandDefaults)
    
    // MARK: Stats Feature
    static let enableStatsFeature = Key<Bool>("enableStatsFeature", default: false, suite: islandDefaults)
    static let enableLLMUsageFeature = Key<Bool>("enableLLMUsageFeature", default: false, suite: islandDefaults)
    static let enableClaudeProvider = Key<Bool>("enableClaudeProvider", default: true, suite: islandDefaults)
    static let enableCodexProvider = Key<Bool>("enableCodexProvider", default: true, suite: islandDefaults)
    static let enableCursorProvider = Key<Bool>("enableCursorProvider", default: true, suite: islandDefaults)
    static let enableAntigravityProvider = Key<Bool>("enableAntigravityProvider", default: true, suite: islandDefaults)
    static let enableNewAPIProvider = Key<Bool>("enableNewAPIProvider", default: false, suite: islandDefaults)
    static let newAPIAccounts = Key<[NewAPIAccount]>("newAPIAccounts", default: [], suite: islandDefaults)
    static let autoStartStatsMonitoring = Key<Bool>("autoStartStatsMonitoring", default: true, suite: islandDefaults)
    static let statsStopWhenNotchCloses = Key<Bool>("statsStopWhenNotchCloses", default: true, suite: islandDefaults)
    static let statsUpdateInterval = Key<Double>("statsUpdateInterval", default: 1.0, suite: islandDefaults)
    static let showCpuGraph = Key<Bool>("showCpuGraph", default: true, suite: islandDefaults)
    static let showMemoryGraph = Key<Bool>("showMemoryGraph", default: true, suite: islandDefaults)
    static let showGpuGraph = Key<Bool>("showGpuGraph", default: true, suite: islandDefaults)
    static let showNetworkGraph = Key<Bool>("showNetworkGraph", default: false, suite: islandDefaults)
    static let showDiskGraph = Key<Bool>("showDiskGraph", default: false, suite: islandDefaults)
    static let cpuTemperatureUnit = Key<LockScreenWeatherTemperatureUnit>("cpuTemperatureUnit", default: .matchingSystemPreference, suite: islandDefaults)
    
    // MARK: Terminal Feature
    static let enableTerminalFeature = Key<Bool>("enableTerminalFeature", default: false, suite: islandDefaults)
    static let terminalShellPath = Key<String>("terminalShellPath", default: "/bin/zsh", suite: islandDefaults)
    static let terminalFontFamily = Key<String>("terminalFontFamily", default: "", suite: islandDefaults)
    static let terminalFontSize = Key<Double>("terminalFontSize", default: 12.0, suite: islandDefaults)
    static let terminalOpacity = Key<Double>("terminalOpacity", default: 1.0, suite: islandDefaults)
    static let terminalMaxHeightFraction = Key<Double>("terminalMaxHeightFraction", default: 0.4, suite: islandDefaults)
    static let terminalCursorStyle = Key<String>("terminalCursorStyle", default: "blinkBlock", suite: islandDefaults)
    static let terminalScrollbackLines = Key<Int>("terminalScrollbackLines", default: 1000, suite: islandDefaults)
    static let terminalOptionAsMeta = Key<Bool>("terminalOptionAsMeta", default: true, suite: islandDefaults)
    static let terminalMouseReporting = Key<Bool>("terminalMouseReporting", default: true, suite: islandDefaults)
    static let terminalBoldAsBright = Key<Bool>("terminalBoldAsBright", default: true, suite: islandDefaults)
    static let terminalBackgroundColor = Key<Color>("terminalBackgroundColor", default: .black, suite: islandDefaults)
    static let terminalForegroundColor = Key<Color>("terminalForegroundColor", default: .white, suite: islandDefaults)
    static let terminalCursorColor = Key<Color>("terminalCursorColor", default: Color(.selectedControlColor), suite: islandDefaults)
    static let terminalStickyMode = Key<Bool>("terminalStickyMode", default: false, suite: islandDefaults)
    
    // MARK: Timer Feature
    static let enableTimerFeature = Key<Bool>("enableTimerFeature", default: true, suite: islandDefaults)
    static let timerDisplayMode = Key<TimerDisplayMode>("timerDisplayMode", default: .tab, suite: islandDefaults)
    static let timerPresets = Key<[TimerPreset]>("timerPresets", default: TimerPreset.defaultPresets, suite: islandDefaults)
    static let showTimerPresetsInNotchTab = Key<Bool>("showTimerPresetsInNotchTab", default: true, suite: islandDefaults)
    static let timerIconColorMode = Key<TimerIconColorMode>("timerIconColorMode", default: .adaptive, suite: islandDefaults)
    static let timerSolidColor = Key<Color>("timerSolidColor", default: .blue, suite: islandDefaults)
    static let timerShowsCountdown = Key<Bool>("timerShowsCountdown", default: true, suite: islandDefaults)
    static let timerShowsLabel = Key<Bool>("timerShowsLabel", default: false, suite: islandDefaults)
    static let timerShowsProgress = Key<Bool>("timerShowsProgress", default: true, suite: islandDefaults)
    static let timerProgressStyle = Key<TimerProgressStyle>("timerProgressStyle", default: .bar, suite: islandDefaults)
    static let mirrorSystemTimer = Key<Bool>("mirrorSystemTimer", default: true, suite: islandDefaults)
    static let timerInputStyle = Key<TimerInputStyle>("timerInputStyle", default: .manual, suite: islandDefaults)
    
    
    // MARK: Reminder Live Activity
    static let enableReminderLiveActivity = Key<Bool>("enableReminderLiveActivity", default: true, suite: islandDefaults)
    static let reminderPresentationStyle = Key<ReminderPresentationStyle>("reminderPresentationStyle", default: .ringCountdown, suite: islandDefaults)
    static let reminderLeadTime = Key<Int>("reminderLeadTime", default: 5, suite: islandDefaults)
    static let reminderSneakPeekDuration = Key<Double>("reminderSneakPeekDuration", default: 5, suite: islandDefaults)
    // Legacy key name: the separate control window is gone, this now shows inline notch controls.
    static let timerControlWindowEnabled = Key<Bool>("timerControlWindowEnabled", default: true, suite: islandDefaults)
    
    // MARK: Per-App Volume
    static let enablePerAppVolume = Key<Bool>("enablePerAppVolume", default: false, suite: islandDefaults)
    static let showPerAppVolumeIcon = Key<Bool>("showPerAppVolumeIcon", default: true, suite: islandDefaults)
    static let perAppVolumeLevels = Key<[String: Double]>("perAppVolumeLevels", default: [:], suite: islandDefaults)
    static let perAppVolumeMuted = Key<Set<String>>("perAppVolumeMuted", default: [])
    // MARK: Caffeinate Feature
    static let enableCaffeinate = Key<Bool>("enableCaffeinate", default: false, suite: islandDefaults)
    static let showCaffeinateIcon = Key<Bool>("showCaffeinateIcon", default: true, suite: islandDefaults)
    static let caffeinateDefaultDuration = Key<CaffeinateDuration>("caffeinateDefaultDuration", default: .indefinite, suite: islandDefaults)
    static let caffeinateKeepsDisplayAwake = Key<Bool>("caffeinateKeepsDisplayAwake", default: true, suite: islandDefaults)

    // MARK: ColorPicker Feature
    static let enableColorPickerFeature = Key<Bool>("enableColorPickerFeature", default: true, suite: islandDefaults)
    static let showColorFormats = Key<Bool>("showColorFormats", default: true, suite: islandDefaults)
    static let colorPickerDisplayMode = Key<ColorPickerDisplayMode>("colorPickerDisplayMode", default: .panel, suite: islandDefaults)
    static let colorHistorySize = Key<Int>("colorHistorySize", default: 10, suite: islandDefaults)
    static let showColorPickerIcon = Key<Bool>("showColorPickerIcon", default: true, suite: islandDefaults)
    
    // MARK: Clipboard Feature
    static let enableClipboardManager = Key<Bool>("enableClipboardManager", default: true, suite: islandDefaults)
    static let clipboardHistorySize = Key<Int>("clipboardHistorySize", default: 3, suite: islandDefaults)
    /// Whether clipboard history is written to disk and restored on launch.
    /// Off keeps it in memory for the session only — nothing survives a quit.
    /// Defaults to true so existing installs keep the behaviour they have.
    static let persistClipboardHistory = Key<Bool>("persistClipboardHistory", default: true, suite: islandDefaults)
    static let showClipboardIcon = Key<Bool>("showClipboardIcon", default: true, suite: islandDefaults)
    static let clipboardDisplayMode = Key<ClipboardDisplayMode>("clipboardDisplayMode", default: .panel, suite: islandDefaults)
    
    // MARK: Screen Assistant Feature
    static let enableScreenAssistant = Key<Bool>("enableScreenAssistant", default: true, suite: islandDefaults)
    static let screenAssistantDisplayMode = Key<ScreenAssistantDisplayMode>("screenAssistantDisplayMode", default: .panel, suite: islandDefaults)
    static let geminiApiKey = Key<String>("geminiApiKey", default: "", suite: islandDefaults)
    static let openaiApiKey = Key<String>("openaiApiKey", default: "", suite: islandDefaults)
    static let claudeApiKey = Key<String>("claudeApiKey", default: "", suite: islandDefaults)
    static let groqApiKey = Key<String>("groqApiKey", default: "", suite: islandDefaults)
    static let selectedAIProvider = Key<AIModelProvider>("selectedAIProvider", default: .gemini, suite: islandDefaults)
    static let selectedAIModel = Key<AIModel?>("selectedAIModel", default: nil, suite: islandDefaults)
    static let enableThinkingMode = Key<Bool>("enableThinkingMode", default: false, suite: islandDefaults)
    static let localModelEndpoint = Key<String>("localModelEndpoint", default: "http://localhost:11434", suite: islandDefaults)

    // MARK: Third-Party Extensions
    static let enableThirdPartyExtensions = Key<Bool>("enableThirdPartyExtensions", default: false, suite: islandDefaults)
    static let enableExtensionLiveActivities = Key<Bool>("enableExtensionLiveActivities", default: true, suite: islandDefaults)
    static let enableExtensionLockScreenWidgets = Key<Bool>("enableExtensionLockScreenWidgets", default: true, suite: islandDefaults)
    static let enableExtensionNotchExperiences = Key<Bool>("enableExtensionNotchExperiences", default: true, suite: islandDefaults)
    static let enableExtensionNotchTabs = Key<Bool>("enableExtensionNotchTabs", default: true, suite: islandDefaults)
    static let enableExtensionNotchMinimalisticOverrides = Key<Bool>("enableExtensionNotchMinimalisticOverrides", default: true, suite: islandDefaults)
    static let enableExtensionNotchInteractiveWebViews = Key<Bool>("enableExtensionNotchInteractiveWebViews", default: true, suite: islandDefaults)
    static let extensionAuthorizationEntries = Key<[ExtensionAuthorizationEntry]>("extensionAuthorizationEntries", default: [], suite: islandDefaults)
    static let extensionRateLimitRecords = Key<[ExtensionRateLimitRecord]>("extensionRateLimitRecords", default: [], suite: islandDefaults)
    static let extensionDiagnosticsLoggingEnabled = Key<Bool>("extensionDiagnosticsLoggingEnabled", default: true, suite: islandDefaults)
    static let extensionLiveActivityCapacity = Key<Int>("extensionLiveActivityCapacity", default: 4, suite: islandDefaults)
    static let extensionLockScreenWidgetCapacity = Key<Int>("extensionLockScreenWidgetCapacity", default: 4, suite: islandDefaults)
    static let extensionNotchExperienceCapacity = Key<Int>("extensionNotchExperienceCapacity", default: 2, suite: islandDefaults)
    static let enableExtensionFileSharing = Key<Bool>("enableExtensionFileSharing", default: true, suite: islandDefaults)
    
    // MARK: Keyboard Shortcuts
    static let enableShortcuts = Key<Bool>("enableShortcuts", default: true, suite: islandDefaults)
    
    // MARK: System HUD Feature
    static let enableSystemHUD = Key<Bool>("enableSystemHUD", default: true, suite: islandDefaults)
    static let enableVolumeHUD = Key<Bool>("enableVolumeHUD", default: true, suite: islandDefaults)
    static let enableBrightnessHUD = Key<Bool>("enableBrightnessHUD", default: true, suite: islandDefaults)
    static let enableKeyboardBacklightHUD = Key<Bool>("enableKeyboardBacklightHUD", default: true, suite: islandDefaults)
    static let systemHUDSensitivity = Key<Int>("systemHUDSensitivity", default: 5, suite: islandDefaults)
    static let playVolumeChangeFeedback = Key<Bool>("playVolumeChangeFeedback", default: false, suite: islandDefaults)

    // Step sizes for hardware media keys (percent of full range, 1-25)
    static let volumeStepPercent = Key<Int>("volumeStepPercent", default: 6, suite: islandDefaults)
    static let volumeFineStepPercent = Key<Int>("volumeFineStepPercent", default: 2, suite: islandDefaults)
    static let brightnessStepPercent = Key<Int>("brightnessStepPercent", default: 6, suite: islandDefaults)
    static let brightnessFineStepPercent = Key<Int>("brightnessFineStepPercent", default: 2, suite: islandDefaults)
    
    // MARK: Custom OSD Window Feature
    static let enableCustomOSD = Key<Bool>("enableCustomOSD", default: false, suite: islandDefaults)
    static let enableVerticalHUD = Key<Bool>("enableVerticalHUD", default: false, suite: islandDefaults)
    static let enableCircularHUD = Key<Bool>("enableCircularHUD", default: false, suite: islandDefaults)
    static let verticalHUDPosition = Key<String>("verticalHUDPosition", default: "right", suite: islandDefaults) // "left" or "right"
    
    // Vertical HUD Customization
    static let verticalHUDShowValue = Key<Bool>("verticalHUDShowValue", default: true, suite: islandDefaults)
    static let verticalHUDInteractive = Key<Bool>("verticalHUDInteractive", default: true, suite: islandDefaults)
    static let verticalHUDHeight = Key<CGFloat>("verticalHUDHeight", default: 160, suite: islandDefaults)
    static let verticalHUDWidth = Key<CGFloat>("verticalHUDWidth", default: 36, suite: islandDefaults)
    static let verticalHUDPadding = Key<CGFloat>("verticalHUDPadding", default: 24, suite: islandDefaults)
    static let verticalHUDUseAccentColor = Key<Bool>("verticalHUDUseAccentColor", default: false, suite: islandDefaults)
    static let verticalHUDMaterial = Key<OSDMaterial>("verticalHUDMaterial", default: .frosted, suite: islandDefaults)
    static let verticalHUDLiquidGlassCustomizationMode = Key<LockScreenGlassCustomizationMode>(
        "verticalHUDLiquidGlassCustomizationMode",
        default: .standard
    , suite: islandDefaults)
    static let verticalHUDLiquidGlassVariant = Key<LiquidGlassVariant>(
        "verticalHUDLiquidGlassVariant",
        default: .defaultVariant
    , suite: islandDefaults)
    
    // Circular HUD Customization
    static let circularHUDShowValue = Key<Bool>("circularHUDShowValue", default: true, suite: islandDefaults)
    static let circularHUDSize = Key<CGFloat>("circularHUDSize", default: 65, suite: islandDefaults)
    static let circularHUDStrokeWidth = Key<CGFloat>("circularHUDStrokeWidth", default: 4, suite: islandDefaults)
    static let circularHUDUseAccentColor = Key<Bool>("circularHUDUseAccentColor", default: true, suite: islandDefaults)

    // MARK: Third-Party DDC Integration
    static let enableThirdPartyDDCIntegration = Key<Bool>("enableThirdPartyDDCIntegration", default: false, suite: islandDefaults)
    static let thirdPartyDDCProvider = Key<ThirdPartyDDCProvider>("thirdPartyDDCProvider", default: .betterDisplay, suite: islandDefaults)
    static let enableExternalVolumeControlListener = Key<Bool>("enableExternalVolumeControlListener", default: false, suite: islandDefaults)
    static let didMigrateThirdPartyDDCIntegration = Key<Bool>("didMigrateThirdPartyDDCIntegration", default: false, suite: islandDefaults)

    // Legacy keys retained for migration/backward compatibility
    static let enableBetterDisplayIntegration = Key<Bool>("enableBetterDisplayIntegration", default: false, suite: islandDefaults)
    static let enableLunarIntegration = Key<Bool>("enableLunarIntegration", default: false, suite: islandDefaults)
    
    static let hasSeenOSDAlphaWarning = Key<Bool>("hasSeenOSDAlphaWarning", default: false, suite: islandDefaults)
    static let enableOSDVolume = Key<Bool>("enableOSDVolume", default: true, suite: islandDefaults)
    static let enableOSDBrightness = Key<Bool>("enableOSDBrightness", default: true, suite: islandDefaults)
    static let enableOSDKeyboardBacklight = Key<Bool>("enableOSDKeyboardBacklight", default: true, suite: islandDefaults)
    static let osdMaterial = Key<OSDMaterial>("osdMaterial", default: .frosted, suite: islandDefaults)
    static let osdLiquidGlassCustomizationMode = Key<LockScreenGlassCustomizationMode>(
        "osdLiquidGlassCustomizationMode",
        default: .standard
    , suite: islandDefaults)
    static let osdLiquidGlassVariant = Key<LiquidGlassVariant>(
        "osdLiquidGlassVariant",
        default: .defaultVariant
    , suite: islandDefaults)
    static let osdIconColorStyle = Key<OSDIconColorStyle>("osdIconColorStyle", default: .white, suite: islandDefaults)
    
    // MARK: Screen Recording Detection Feature
    static let enableScreenRecordingDetection = Key<Bool>("enableScreenRecordingDetection", default: true, suite: islandDefaults)
    static let showRecordingIndicator = Key<Bool>("showRecordingIndicator", default: true, suite: islandDefaults)
    static let recordingHoverStyle = Key<RecordingHoverStyle>("recordingHoverStyle", default: .default, suite: islandDefaults)
    static let recordingControlMode = Key<RecordingControlMode>("recordingControlMode", default: .withStopButton, suite: islandDefaults)
    // Polling removed - now uses event-driven private API detection (CGSIsScreenWatcherPresent)
    // static let enableScreenRecordingPolling = Key<Bool>("enableScreenRecordingPolling", default: false, suite: islandDefaults)

    // MARK: Focus / Do Not Disturb Detection
    static let enableDoNotDisturbDetection = Key<Bool>("enableDoNotDisturbDetection", default: true, suite: islandDefaults)
    static let focusMonitoringMode = Key<FocusMonitoringMode>("focusMonitoringMode", default: .withoutDevTools, suite: islandDefaults)
    static let showDoNotDisturbIndicator = Key<Bool>("showDoNotDisturbIndicator", default: true, suite: islandDefaults)
    static let showDoNotDisturbLabel = Key<Bool>("showDoNotDisturbLabel", default: true, suite: islandDefaults)
    static let focusIndicatorNonPersistent = Key<Bool>("focusIndicatorNonPersistent", default: false, suite: islandDefaults)
    
    // MARK: Privacy Indicators (Camera & Microphone Detection)
    static let enableCameraDetection = Key<Bool>("enableCameraDetection", default: true, suite: islandDefaults)
    static let enableMicrophoneDetection = Key<Bool>("enableMicrophoneDetection", default: true, suite: islandDefaults)
    
    // MARK: Lock Screen Features
    static let enableLockScreenLiveActivity = Key<Bool>("enableLockScreenLiveActivity", default: true, suite: islandDefaults)
    static let lockScreenLiveActivityIconStyle = Key<LockScreenLiveActivityIconStyle>("lockScreenLiveActivityIconStyle", default: .lock, suite: islandDefaults)
    static let enableLockSounds = Key<Bool>("enableLockSounds", default: true, suite: islandDefaults)
    
    // MARK: Caps Lock Indicator
    static let enableCapsLockIndicator = Key<Bool>("enableCapsLockIndicator", default: true, suite: islandDefaults)
    static let capsLockIndicatorUseGreenColor = Key<Bool>("capsLockIndicatorUseGreenColor", default: false, suite: islandDefaults) // Legacy toggle
    static let capsLockIndicatorTintMode = Key<CapsLockIndicatorTintMode>("capsLockIndicatorTintMode", default: .white, suite: islandDefaults)
    static let didMigrateCapsLockTintMode = Key<Bool>("didMigrateCapsLockTintMode", default: false, suite: islandDefaults)
    static let didMigrateClipboardShortcutToV = Key<Bool>("didMigrateClipboardShortcutToV", default: false, suite: islandDefaults)
    static let showCapsLockLabel = Key<Bool>("showCapsLockLabel", default: false, suite: islandDefaults)
    
    // MARK: ImageService
    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCacheV1", default: false, suite: islandDefaults)
    
    // MARK: Minimalistic UI Mode
    static let enableMinimalisticUI = Key<Bool>("enableMinimalisticUI", default: false, suite: islandDefaults)
    
    // MARK: Lyrics Feature
    static let enableLyrics = Key<Bool>("enableLyrics", default: false, suite: islandDefaults)

    /// Whether the sung line is swept or simply lit.
    static let lyricHighlightStyle = Key<LyricHighlightStyle>("lyricHighlightStyle", default: .sweep, suite: islandDefaults)
    /// Keeps the current line under the closed notch after the panel is gone.
    static let pinnedLyricContext = Key<PinnedLyricContext>("pinnedLyricContext", default: .current, suite: islandDefaults)
    static let pinLyricsWhenClosed = Key<Bool>("pinLyricsWhenClosed", default: false, suite: islandDefaults)
    static let lyricsPanelWidth = Key<CGFloat>("lyricsPanelWidth", default: 280, suite: islandDefaults)
    static let lyricsPanelOffset = Key<CGFloat>("lyricsPanelOffset", default: 0, suite: islandDefaults)
    static let showLiveCanvasInDynamicIsland = Key<Bool>("showLiveCanvasInDynamicIsland", default: false, suite: islandDefaults)
    
    // MARK: Notes Feature
    static let enableNotes = Key<Bool>("enableNotes", default: false, suite: islandDefaults)
    static let enableNotePinning = Key<Bool>("enableNotePinning", default: true, suite: islandDefaults)
    static let enableNoteSearch = Key<Bool>("enableNoteSearch", default: false, suite: islandDefaults)
    static let enableNoteColorFiltering = Key<Bool>("enableNoteColorFiltering", default: false, suite: islandDefaults)
    static let enableCreateFromClipboard = Key<Bool>("enableCreateFromClipboard", default: true, suite: islandDefaults)
    static let enableNoteCharCount = Key<Bool>("enableNoteCharCount", default: true, suite: islandDefaults)
    static let savedNotes = Key<[NoteItem]>("savedNotes", default: [], suite: islandDefaults)
    static let enableAppleNotesSync = Key<Bool>("enableAppleNotesSync", default: false, suite: islandDefaults)
    static let appleNotesLastSyncDate = Key<Date?>("appleNotesLastSyncDate", default: nil, suite: islandDefaults)
    
    // Helper to determine the default media controller based on macOS version
    static var defaultMediaController: MediaControllerType {
        if #available(macOS 15.4, *) {
            return .appleMusic
        } else {
            return .nowPlaying
        }
    }
    
    // Migration helper to convert from legacy enableGradient Boolean to new ProgressBarStyle enum
    static func migrateProgressBarStyle() {
        // Check if migration is needed by seeing if the old Boolean was set to gradient
        let wasGradientEnabled = Defaults[.enableGradient]
        
        // Only migrate if we're still using the default hierarchical value but gradient was enabled
        if wasGradientEnabled && Defaults[.progressBarStyle] == .hierarchical {
            Defaults[.progressBarStyle] = .gradient
        }
    }

    static func migrateMusicAuxControls() {
        if Defaults[.didMigrateMusicAuxControls] == false {
            if Defaults[.showMediaOutputControl] {
                Defaults[.musicAuxRightControl] = .mediaOutput
            }

            Defaults[.didMigrateMusicAuxControls] = true
        }

        normalizeMusicAuxControls()
    }

    /// Move the clipboard shortcut off the old Cmd+Shift+C default.
    ///
    /// Settings has always documented Cmd+Shift+V ("similar to Windows+V on PC") while the
    /// shortcut was registered as Cmd+Shift+C. Changing the default alone fixes nothing for
    /// anyone who has already launched Atoll: `KeyboardShortcuts.Name` writes its default into
    /// UserDefaults on first run and never overwrites it, so the old value would win forever.
    ///
    /// Only a shortcut still sitting on the old default is moved. Anyone who picked their own
    /// keeps it — including, unavoidably, anyone who deliberately chose Cmd+Shift+C.
    ///
    /// The marker is written last: if this crashed between marking and moving, the migration
    /// would be considered done while the shortcut still sat on the old key, with no second
    /// chance to correct it. Running twice is harmless by comparison, since the second run
    /// finds Cmd+Shift+V rather than the legacy default and changes nothing.
    static func migrateClipboardShortcutToV() {
        guard Defaults[.didMigrateClipboardShortcutToV] == false else { return }

        let legacyDefault = KeyboardShortcuts.Shortcut(.c, modifiers: [.shift, .command])
        if KeyboardShortcuts.getShortcut(for: .clipboardHistoryPanel) == legacyDefault {
            KeyboardShortcuts.setShortcut(.init(.v, modifiers: [.shift, .command]), for: .clipboardHistoryPanel)
        }

        Defaults[.didMigrateClipboardShortcutToV] = true
    }

    static func migrateCapsLockTintMode() {
        guard Defaults[.didMigrateCapsLockTintMode] == false else { return }

        let legacyGreen = Defaults[.capsLockIndicatorUseGreenColor]
        Defaults[.capsLockIndicatorTintMode] = legacyGreen ? .green : .white
        Defaults[.didMigrateCapsLockTintMode] = true
    }

    static func migrateMusicControlSlots() {
        guard Defaults[.didMigrateMusicControlSlots] == false else { return }

        let allowMediaOutput = Defaults[.showMediaOutputControl]
        let baseLayout: [MusicControlButton]

        if Defaults[.showShuffleAndRepeat] {
            var slots = MusicControlButton.defaultLayout
            let left = MusicControlButton(auxiliaryControl: Defaults[.musicAuxLeftControl])
            let right = MusicControlButton(auxiliaryControl: Defaults[.musicAuxRightControl])
            slots[0] = left
            slots[4] = right
            baseLayout = slots
        } else {
            baseLayout = MusicControlButton.minimalLayout
        }

        Defaults[.musicControlSlots] = baseLayout.normalized(allowingMediaOutput: allowMediaOutput)
        Defaults[.didMigrateMusicControlSlots] = true
    }

    static func migrateThirdPartyDDCIntegration() {
        if Defaults[.didMigrateThirdPartyDDCIntegration] == false {
            let legacyBetterDisplayEnabled = Defaults[.enableBetterDisplayIntegration]
            let legacyLunarEnabled = Defaults[.enableLunarIntegration]

            if legacyBetterDisplayEnabled || legacyLunarEnabled {
                Defaults[.enableThirdPartyDDCIntegration] = true
                Defaults[.thirdPartyDDCProvider] = (legacyLunarEnabled && !legacyBetterDisplayEnabled) ? .lunar : .betterDisplay
            }

            Defaults[.didMigrateThirdPartyDDCIntegration] = true
        }

        syncLegacyThirdPartyDDCKeys()
    }

    static func syncLegacyThirdPartyDDCKeys() {
        let isIntegrationEnabled = Defaults[.enableThirdPartyDDCIntegration]
        let selectedProvider = Defaults[.thirdPartyDDCProvider]
        Defaults[.enableBetterDisplayIntegration] = isIntegrationEnabled && selectedProvider == .betterDisplay
        Defaults[.enableLunarIntegration] = isIntegrationEnabled && selectedProvider == .lunar
    }

    private static func normalizeMusicAuxControls() {
        guard Defaults[.musicAuxLeftControl] == Defaults[.musicAuxRightControl] else { return }

        let current = Defaults[.musicAuxLeftControl]
        let fallback = MusicAuxiliaryControl.alternative(excluding: current)
        Defaults[.musicAuxRightControl] = fallback
    }
    static let showSongMetadataInClosedNotch = Key<Bool>("showSongMetadataInClosedNotch", default: false, suite: islandDefaults)
}
