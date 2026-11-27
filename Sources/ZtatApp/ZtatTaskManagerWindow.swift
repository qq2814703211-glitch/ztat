// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Standalone Activity Monitor & Task Manager Window Controller
// with Real Carbon RegisterEventHotKey Global Shortcut (default ⌃⇧⎋, customizable, zero Input Monitoring needed).

import AppKit
import Carbon.HIToolbox
import SwiftUI
import ZtatCore
import ZtatStatsHost

// MARK: - Customizable Global Shortcut Store (Carbon RegisterEventHotKey)

@MainActor
public final class ZtatTaskManagerShortcutStore: ObservableObject {
    public static let shared = ZtatTaskManagerShortcutStore()

    private enum Keys {
        static let enabled = "dev.ztat.taskmanager.shortcut.enabled"
        static let keyCode = "dev.ztat.taskmanager.shortcut.keyCode"
        static let modifiers = "dev.ztat.taskmanager.shortcut.carbonModifiers"
        static let openInMainSettings = "dev.ztat.taskmanager.shortcut.openInMainSettings"
    }

    // Default: Control + Shift + Escape (⌃⇧⎋) — universal Task Manager shortcut, zero conflict with macOS ⌘⌥⎋
    public static let defaultKeyCode: UInt32 = UInt32(kVK_Escape)
    public static let defaultCarbonModifiers: UInt32 = UInt32(controlKey | shiftKey)

    private var suppressSync: Bool = false

    @Published public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            if !suppressSync { syncCarbonHotKey() }
        }
    }
    @Published public var keyCode: UInt32 {
        didSet {
            UserDefaults.standard.set(Int(keyCode), forKey: Keys.keyCode)
            if !suppressSync { syncCarbonHotKey() }
        }
    }
    @Published public var carbonModifiers: UInt32 {
        didSet {
            UserDefaults.standard.set(Int(carbonModifiers), forKey: Keys.modifiers)
            if !suppressSync { syncCarbonHotKey() }
        }
    }
    @Published public var openInMainSettings: Bool {
        didSet {
            UserDefaults.standard.set(openInMainSettings, forKey: Keys.openInMainSettings)
        }
    }
    @Published public private(set) var registrationFailed: Bool = false
    @Published public private(set) var validationWarning: String? = nil

    private var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) static var eventHandlerRef: EventHandlerRef?
    private nonisolated(unsafe) static var isHotKeyPressed: Bool = false
    private static let hotKeySignature: OSType = 0x5A54_544D // 'ZTTM'
    private static let hotKeyID: UInt32 = 1

    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: Keys.enabled) == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = d.bool(forKey: Keys.enabled)
        }
        if d.object(forKey: Keys.keyCode) != nil,
           let kc = UInt32(exactly: d.integer(forKey: Keys.keyCode)),
           let mods = UInt32(exactly: d.integer(forKey: Keys.modifiers)),
           Self.isValidShortcut(keyCode: kc, carbonModifiers: mods) {
            self.keyCode = kc
            self.carbonModifiers = mods
        } else {
            self.keyCode = Self.defaultKeyCode
            self.carbonModifiers = Self.defaultCarbonModifiers
        }
        self.openInMainSettings = d.bool(forKey: Keys.openInMainSettings)
    }

    public var displayString: String {
        Self.formatShortcut(keyCode: keyCode, carbonModifiers: carbonModifiers)
    }

    public static func isStandaloneFunctionKey(_ keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
             kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20:
            return true
        default:
            return false
        }
    }

    public static func isReservedSystemShortcut(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        let allMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let mods = carbonModifiers & allMask
        if mods == UInt32(cmdKey) {
            switch Int(keyCode) {
            case kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M,
                 kVK_Tab, kVK_Space,
                 kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_A, kVK_ANSI_Z:
                return true
            default:
                break
            }
        }
        // macOS system Force Quit dialog (⌘⌥⎋)
        if mods == UInt32(cmdKey | optionKey) && Int(keyCode) == kVK_Escape {
            return true
        }
        return false
    }

    public static func isValidShortcut(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        guard !isReservedSystemShortcut(keyCode: keyCode, carbonModifiers: carbonModifiers) else {
            return false
        }
        if isStandaloneFunctionKey(keyCode) {
            return true
        }
        let primaryMask = UInt32(cmdKey | optionKey | controlKey)
        return (carbonModifiers & primaryMask) != 0
    }

    @discardableResult
    public func updateShortcut(keyCode: UInt32, cocoaModifiers: NSEvent.ModifierFlags) -> Bool {
        let mods = Self.cocoaToCarbonModifiers(cocoaModifiers)
        if Self.isReservedSystemShortcut(keyCode: keyCode, carbonModifiers: mods) {
            validationWarning = ZtatL10n.tr(
                "该组合键为 macOS 系统保留快捷键（如 ⌘Q/⌘W/⌘Space/⌘⌥⎋），请选择其他组合。",
                "This combination is reserved by macOS (e.g. ⌘Q/⌘W/⌘Space/⌘⌥⎋). Please pick another."
            )
            return false
        }
        guard Self.isValidShortcut(keyCode: keyCode, carbonModifiers: mods) else {
            validationWarning = ZtatL10n.tr(
                "快捷键必须包含 ⌃ / ⌥ / ⌘ 修饰键之一（或单独使用 F1–F20 功能键）。",
                "Shortcut must include ⌃, ⌥, or ⌘ (or be a standalone F1–F20 function key)."
            )
            return false
        }
        validationWarning = nil
        suppressSync = true
        self.keyCode = keyCode
        self.carbonModifiers = mods
        suppressSync = false
        syncCarbonHotKey()
        return true
    }

    public func clearValidationWarning() {
        validationWarning = nil
    }

    public func resetToDefault() {
        validationWarning = nil
        suppressSync = true
        self.keyCode = Self.defaultKeyCode
        self.carbonModifiers = Self.defaultCarbonModifiers
        self.isEnabled = true
        suppressSync = false
        syncCarbonHotKey()
    }

    public func syncCarbonHotKey() {
        unregisterCarbonHotKey(removeHandler: false)
        guard isEnabled else {
            registrationFailed = false
            return
        }
        guard Self.installCarbonHandlerIfNeeded() else {
            self.hotKeyRef = nil
            self.registrationFailed = true
            return
        }
        let id = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            id,
            GetEventDispatcherTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        if status == noErr, let ref {
            self.hotKeyRef = ref
            self.registrationFailed = false
        } else {
            self.hotKeyRef = nil
            self.registrationFailed = true
        }
    }

    public func unregisterCarbonHotKey(removeHandler: Bool = false) {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        Self.isHotKeyPressed = false
        if removeHandler {
            Self.removeCarbonHandler()
        }
    }

    @discardableResult
    private static func installCarbonHandlerIfNeeded() -> Bool {
        if eventHandlerRef != nil { return true }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let paramStatus = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )
            guard paramStatus == noErr,
                  id.signature == ZtatTaskManagerShortcutStore.hotKeySignature,
                  id.id == ZtatTaskManagerShortcutStore.hotKeyID else {
                return OSStatus(eventNotHandledErr)
            }
            let kind = GetEventKind(event)
            if kind == UInt32(kEventHotKeyReleased) {
                ZtatTaskManagerShortcutStore.isHotKeyPressed = false
                return noErr
            }
            if kind == UInt32(kEventHotKeyPressed) {
                guard !ZtatTaskManagerShortcutStore.isHotKeyPressed else {
                    return noErr
                }
                ZtatTaskManagerShortcutStore.isHotKeyPressed = true
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        ZtatTaskManagerWindowController.shared.handleGlobalShortcutTrigger()
                    }
                }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }, specs.count, &specs, nil, &ref)
        if status == noErr, let ref {
            eventHandlerRef = ref
            return true
        }
        return false
    }

    private static func removeCarbonHandler() {
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        isHotKeyPressed = false
    }

    public static func cocoaToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return mods
    }

    public static func formatShortcut(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var str = ""
        if (carbonModifiers & UInt32(controlKey)) != 0 { str += "⌃" }
        if (carbonModifiers & UInt32(optionKey))  != 0 { str += "⌥" }
        if (carbonModifiers & UInt32(shiftKey))   != 0 { str += "⇧" }
        if (carbonModifiers & UInt32(cmdKey))     != 0 { str += "⌘" }
        str += keyName(for: keyCode)
        return str
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Escape: return "⎋"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        default: return "#\(keyCode)"
        }
    }
}

// MARK: - SwiftUI Shortcut Recorder & Settings Section

struct ZtatTaskManagerShortcutSettingsSection: View {
    @ObservedObject private var store = ZtatTaskManagerShortcutStore.shared
    @State private var isRecording = false
    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?
    @State private var cancelObservers: [NSObjectProtocol] = []

    var body: some View {
        Section(ZtatL10n.tr("任务管理器与全局快捷键", "Task Manager & Global Shortcut")) {
            Toggle(
                ZtatL10n.tr("启用全局快捷键快速唤出任务管理器", "Enable Global Shortcut to Toggle Task Manager"),
                isOn: $store.isEnabled
            )

            HStack {
                Text(ZtatL10n.tr("快捷键组合", "Shortcut"))
                Spacer()
                Button {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                } label: {
                    Text(isRecording ? ZtatL10n.tr("请按下组合键（Esc 取消）…", "Press Shortcut (Esc to Cancel)…") : store.displayString)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(isRecording ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Button(ZtatL10n.tr("重置 ⌃⇧⎋", "Reset ⌃⇧⎋")) {
                    stopRecording()
                    store.resetToDefault()
                }
                .controlSize(.small)
            }

            if let warn = store.validationWarning {
                Text(warn)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if store.registrationFailed {
                Text(ZtatL10n.tr("该快捷键已被系统或其他应用占用，请录制新的组合键。", "This shortcut is already claimed by macOS or another app. Please choose another combination."))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Picker(ZtatL10n.tr("快捷键打开方式", "Shortcut Opens"), selection: $store.openInMainSettings) {
                Text(ZtatL10n.tr("独立任务管理器窗口（推荐）", "Standalone Activity Monitor Window")).tag(false)
                Text(ZtatL10n.tr("ztat 主控制窗口中的任务管理器页", "Task Manager Inside ztat Main Window")).tag(true)
            }

            HStack {
                Button(ZtatL10n.tr("立即打开独立任务管理器", "Open Standalone Task Manager")) {
                    ZtatTaskManagerWindowController.shared.show()
                }
                .controlSize(.small)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        store.clearValidationWarning()
        store.unregisterCarbonHotKey(removeHandler: false)
        isRecording = true

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.isARepeat { return nil }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape) && mods.isEmpty {
                store.clearValidationWarning()
                stopRecording()
                return nil
            }
            if store.updateShortcut(keyCode: UInt32(event.keyCode), cocoaModifiers: mods) {
                stopRecording()
            }
            return nil
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            stopRecording()
            return event
        }

        let names: [Notification.Name] = [
            NSApplication.didResignActiveNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification
        ]
        cancelObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    stopRecording()
                }
            }
        }
    }

    private func stopRecording() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
        for obs in cancelObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        cancelObservers.removeAll()

        if isRecording {
            isRecording = false
            store.syncCarbonHotKey()
        }
    }
}

// MARK: - Reactive Standalone Window Root Wrapper

private struct StandaloneTaskManagerRootView: View {
    let consumerID: String
    @ObservedObject private var shortcutStore = ZtatTaskManagerShortcutStore.shared
    @ObservedObject private var l10n = ZtatLocalizationStore.shared

    var body: some View {
        let _ = l10n.revision
        ZtatTaskManagerView(
            model: VitalsDashboardModel.shared,
            consumerID: consumerID,
            isEmbeddedInSettings: false,
            shortcutDisplayHint: shortcutStore.displayString
        )
    }
}

// MARK: - Standalone Task Manager Window Controller

@MainActor
public final class ZtatTaskManagerWindowController: NSObject, NSWindowDelegate {
    public static let shared = ZtatTaskManagerWindowController()

    private static let defaultSize = NSSize(width: 1180, height: 760)
    private static let minWindowSize = NSSize(width: 900, height: 560)
    private static let consumerID = "taskmanager.standalone.window"

    private var window: NSWindow?
    private var languageObserver: NSObjectProtocol?

    public func installGlobalShortcutIfNeeded() {
        ZtatTaskManagerShortcutStore.shared.syncCarbonHotKey()
    }

    public func uninstallGlobalShortcut() {
        ZtatTaskManagerShortcutStore.shared.unregisterCarbonHotKey(removeHandler: true)
    }

    public func handleGlobalShortcutTrigger() {
        if ZtatTaskManagerShortcutStore.shared.openInMainSettings {
            ZtatSettingsWindowController.shared.show(route: .taskManager)
        } else {
            toggle()
        }
    }

    public func toggle() {
        if let win = window,
           win.isVisible,
           !win.isMiniaturized,
           win.isOnActiveSpace,
           (win.isKeyWindow || NSApp.isActive) {
            win.orderOut(nil)
            VitalsDashboardModel.shared.endConsumer(Self.consumerID)
        } else {
            show()
        }
    }

    public func show() {
        VitalsDashboardModel.shared.beginConsumer(Self.consumerID)

        if let existing = window {
            if existing.isMiniaturized {
                existing.deminiaturize(nil)
            }
            let isOnAnyScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(existing.frame) }
            if !isOnAnyScreen || existing.frame.width < Self.minWindowSize.width || existing.frame.height < Self.minWindowSize.height {
                existing.setContentSize(Self.defaultSize)
                existing.center()
            }
            existing.title = ZtatL10n.tr("ztat 任务管理器", "ztat Activity Monitor")
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = StandaloneTaskManagerRootView(consumerID: Self.consumerID)
        let hosting = NSHostingController(rootView: rootView)
        // CRITICAL: Prevent SwiftUI NSHostingController from collapsing NSWindow frame to intrinsic size
        hosting.sizingOptions = []

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = ZtatL10n.tr("ztat 任务管理器", "ztat Activity Monitor")
        win.minSize = Self.minWindowSize
        win.contentViewController = hosting

        // Set centered default size BEFORE attempting frame restore so first launch never opens at (0, 0).
        win.setContentSize(Self.defaultSize)
        win.center()
        let restored = win.setFrameUsingName("dev.ztat.taskmanager.window")
        _ = win.setFrameAutosaveName("dev.ztat.taskmanager.window")
        let isOnAnyScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(win.frame) }
        if !restored || !isOnAnyScreen || win.frame.width < Self.minWindowSize.width || win.frame.height < Self.minWindowSize.height {
            win.setContentSize(Self.defaultSize)
            win.center()
        }
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.toolbarStyle = .unified
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win

        if languageObserver == nil {
            languageObserver = NotificationCenter.default.addObserver(
                forName: .ztatLanguageDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.window?.title = ZtatL10n.tr("ztat 任务管理器", "ztat Activity Monitor")
                }
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        VitalsDashboardModel.shared.endConsumer(Self.consumerID)
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        VitalsDashboardModel.shared.endConsumer(Self.consumerID)
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        VitalsDashboardModel.shared.beginConsumer(Self.consumerID)
    }
}
