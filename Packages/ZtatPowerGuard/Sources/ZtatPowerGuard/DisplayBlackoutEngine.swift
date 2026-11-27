// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics
import IOKit.pwr_mgt
import ZtatCore

/// Clean-room 3-tier built-in display brightness & physical 0% blackout controller + leak-free framebuffer wake guard.
/// Improvements over legacy approaches:
/// - Explicitly targets built-in display via CGDisplayIsBuiltin (never falsely succeeds on external main display).
/// - 3-tier API fallback: DisplayServices -> CoreDisplay (with readback verification) -> IODisplayConnect.
/// - Crash-safe UserDefaults recovery for pre-blackout brightness.
/// - Reusable IOPMAssertionDeclareUserActivity assertion ID (zero kernel assertion leaks).
public final class DisplayBlackoutEngine: @unchecked Sendable {
    public static let shared = DisplayBlackoutEngine()

    private typealias DSGetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DSSetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CDGetBrightnessFn = @convention(c) (CGDirectDisplayID) -> Double
    private typealias CDSetBrightnessFn = @convention(c) (CGDirectDisplayID, Double) -> Void

    private let lock = NSLock()
    private var dsGet: DSGetBrightnessFn?
    private var dsSet: DSSetBrightnessFn?
    private var cdGet: CDGetBrightnessFn?
    private var cdSet: CDSetBrightnessFn?
    private var symbolsLoaded = false

    private var userActivityAssertionID: IOPMAssertionID = 0
    private var _isBlackoutActive = false
    private var _savedBrightness: Float?

    public var isBlackoutActive: Bool {
        lock.withLock { _isBlackoutActive }
    }

    public var savedBrightness: Float? {
        lock.withLock { _savedBrightness }
    }

    private init() {
        loadPrivateSymbols()
        if let persisted = PowerGuardDefaults.store.object(forKey: PowerGuardDefaultsKey.savedBlackoutBrightness) as? Double {
            _savedBrightness = Float(persisted)
        }
    }

    deinit {
        releaseFramebufferWakeAssertion()
    }

    private func loadPrivateSymbols() {
        lock.withLock {
            guard !symbolsLoaded else { return }
            symbolsLoaded = true
            if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
                if let s = dlsym(handle, "DisplayServicesGetBrightness") {
                    dsGet = unsafeBitCast(s, to: DSGetBrightnessFn.self)
                }
                if let s = dlsym(handle, "DisplayServicesSetBrightness") {
                    dsSet = unsafeBitCast(s, to: DSSetBrightnessFn.self)
                }
            }
            if let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY) {
                if let s = dlsym(handle, "CoreDisplay_Display_GetUserBrightness") {
                    cdGet = unsafeBitCast(s, to: CDGetBrightnessFn.self)
                }
                if let s = dlsym(handle, "CoreDisplay_Display_SetUserBrightness") {
                    cdSet = unsafeBitCast(s, to: CDSetBrightnessFn.self)
                }
            }
        }
    }

    /// Returns true if this Mac has an online built-in laptop panel.
    public func hasBuiltInDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return false
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            return false
        }
        return ids.prefix(Int(count)).contains(where: { CGDisplayIsBuiltin($0) != 0 })
    }

    /// Returns the built-in laptop panel ID if present, otherwise falls back to main display.
    public func targetBuiltInDisplayID() -> CGDirectDisplayID {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return CGMainDisplayID()
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            return CGMainDisplayID()
        }
        if let builtin = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            return builtin
        }
        return CGMainDisplayID()
    }

    public func readBrightness(displayID: CGDirectDisplayID? = nil) -> Float? {
        let target = displayID ?? targetBuiltInDisplayID()
        let (dsG, cdG) = lock.withLock { (dsGet, cdGet) }

        if let dsG {
            var level: Float = 0
            if dsG(target, &level) == 0, level.isFinite, level >= 0, level <= 1.0 {
                return level
            }
        }
        if let cdG {
            let level = cdG(target)
            if level.isFinite, level >= 0, level <= 1.0 {
                return Float(level)
            }
        }
        return readIOKitBrightness()
    }

    @discardableResult
    public func setBrightness(_ value: Float, displayID: CGDirectDisplayID? = nil) -> Bool {
        let clamped = max(0.0, min(1.0, value))
        let target = displayID ?? targetBuiltInDisplayID()
        let (dsS, cdS, cdG) = lock.withLock { (dsSet, cdSet, cdGet) }

        if let dsS, dsS(target, clamped) == 0 {
            return true
        }
        if let cdS {
            cdS(target, Double(clamped))
            if let cdG {
                let verified = Float(cdG(target))
                if abs(verified - clamped) < 0.08 {
                    return true
                }
            }
        }
        return writeIOKitBrightness(clamped)
    }

    /// Drops built-in panel backlight to 0% while declaring display user activity so GPU/remote capture stays live.
    @discardableResult
    public func enableBlackout() -> Bool {
        guard hasBuiltInDisplay() else {
            ZtatLog.powerGuard.info("Skipped physical blackout: no built-in display present")
            return false
        }
        let current = readBrightness()
        let toSave: Float = {
            if let c = current, c > 0.05 { return c }
            if let existing = savedBrightness, existing > 0.05 { return existing }
            return 0.65
        }()

        // Persist BEFORE mutating hardware brightness so a crash can always recover.
        PowerGuardDefaults.store.set(Double(toSave), forKey: PowerGuardDefaultsKey.savedBlackoutBrightness)
        lock.withLock { _savedBrightness = toSave }

        renewFramebufferWakeAssertion()
        let ok = setBrightness(0.0)
        if ok {
            lock.withLock { _isBlackoutActive = true }
            ZtatLog.powerGuard.info("Physical blackout enabled (saved brightness: \(Int(toSave * 100))%)")
        } else {
            PowerGuardDefaults.store.removeObject(forKey: PowerGuardDefaultsKey.savedBlackoutBrightness)
        }
        return ok
    }

    /// Restores saved brightness with retry support (handles display wake/lid-open races).
    @discardableResult
    public func disableBlackout(retryOnFailure: Bool = true) -> Bool {
        let saved = lock.withLock { _savedBrightness }
            ?? (PowerGuardDefaults.store.object(forKey: PowerGuardDefaultsKey.savedBlackoutBrightness) as? Double).map { Float($0) }
            ?? 0.65
        let target = max(0.08, min(1.0, saved))

        let ok = setBrightness(target)
        if ok {
            clearBlackoutState()
            ZtatLog.powerGuard.info("Physical blackout disabled (restored brightness: \(Int(target * 100))%)")
            return true
        }

        if retryOnFailure {
            scheduleRestoreRetries(target: target, remainingAttempts: 6)
        }
        return false
    }

    /// Clears blackout tracking if the user manually raised brightness using hardware keys (F2).
    public func reconcileExternalBrightnessChange() -> Bool {
        guard isBlackoutActive else { return false }
        if let current = readBrightness(), current > 0.04 {
            clearBlackoutState()
            ZtatLog.powerGuard.info("Detected manual brightness increase (\(Int(current * 100))%); exiting blackout mode")
            return true
        }
        return false
    }

    /// Recovers brightness if the previous ztat process crashed while blackout was active.
    @discardableResult
    public func recoverFromCrashIfNeeded() -> Bool {
        guard let persisted = PowerGuardDefaults.store.object(forKey: PowerGuardDefaultsKey.savedBlackoutBrightness) as? Double else {
            return false
        }
        if let current = readBrightness(), current > 0.04 {
            PowerGuardDefaults.store.removeObject(forKey: PowerGuardDefaultsKey.savedBlackoutBrightness)
            return false
        }
        let target = max(0.08, min(1.0, Float(persisted)))
        let ok = setBrightness(target)
        if ok {
            clearBlackoutState()
        } else {
            scheduleRestoreRetries(target: target, remainingAttempts: 6)
        }
        return ok
    }

    private func clearBlackoutState() {
        lock.withLock {
            _isBlackoutActive = false
            _savedBrightness = nil
        }
        PowerGuardDefaults.store.removeObject(forKey: PowerGuardDefaultsKey.savedBlackoutBrightness)
    }

    private func scheduleRestoreRetries(target: Float, remainingAttempts: Int) {
        guard remainingAttempts > 0 else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if self.setBrightness(target) {
                self.clearBlackoutState()
            } else {
                self.scheduleRestoreRetries(target: target, remainingAttempts: remainingAttempts - 1)
            }
        }
    }

    /// Reuses a single IOPMAssertionID to keep display framebuffer / GPU alive for remote desktop without leaking IDs.
    public func renewFramebufferWakeAssertion() {
        lock.withLock {
            var id = userActivityAssertionID
            let kr = IOPMAssertionDeclareUserActivity(
                "ztat Framebuffer Wake Guard" as CFString,
                kIOPMUserActiveLocal,
                &id
            )
            if kr == kIOReturnSuccess {
                userActivityAssertionID = id
            }
        }
    }

    public func releaseFramebufferWakeAssertion() {
        lock.withLock {
            guard userActivityAssertionID != 0 else { return }
            IOPMAssertionRelease(userActivityAssertionID)
            userActivityAssertionID = 0
        }
    }

    // MARK: - Legacy IOKit IODisplayConnect Fallback

    private func readIOKitBrightness() -> Float? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }
            var level: Float = 0
            if IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                return level
            }
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    private func writeIOKitBrightness(_ value: Float) -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        var updated = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }
            if IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, value) == kIOReturnSuccess {
                updated = true
            }
            service = IOIteratorNext(iterator)
        }
        return updated
    }
}
