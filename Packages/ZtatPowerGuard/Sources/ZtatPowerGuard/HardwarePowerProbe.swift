// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import ZtatCore

/// Event-driven hardware power & lid probe (zero idle polling).
/// Uses IOServiceAddInterestNotification on IOPMrootDomain and IOPSNotificationCreateRunLoopSource.
public final class HardwarePowerProbe: @unchecked Sendable {
    public static let shared = HardwarePowerProbe()

    private let lock = NSLock()
    private var notifyPort: IONotificationPortRef?
    private var rootDomainInterest: io_object_t = 0
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var onChangeHandler: (@Sendable () -> Void)?

    public let cachedHardwareModel: String
    public let cachedOSVersion: String

    private init() {
        cachedHardwareModel = Self.sysctlString("hw.model") ?? "Mac"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        cachedOSVersion = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public func readRootDomainState() -> (lidClosed: Bool, sleepDisabled: Bool) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return (false, false) }
        defer { IOObjectRelease(service) }

        let lid = (IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
        let sleepDisabled = (IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
        return (lid, sleepDisabled)
    }

    /// Reads internal battery state only (filters strictly by kIOPSInternalBatteryType so UPS/accessories never override battery %).
    public func readPowerSource() -> (isOnAC: Bool, percentage: Int?, isCharging: Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return (true, nil, false)
        }
        let providingType = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as? String
        let isOnAC = (providingType == kIOPSACPowerValue)

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let type = desc[kIOPSTypeKey] as? String, type != kIOPSInternalBatteryType {
                continue
            }
            let current = desc[kIOPSCurrentCapacityKey] as? Int
            let maxCap = desc[kIOPSMaxCapacityKey] as? Int
            let pct: Int? = {
                if let c = current, let m = maxCap, m > 0 {
                    return max(0, min(100, Int((Double(c) / Double(m) * 100.0).rounded())))
                }
                return current
            }()
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            return (isOnAC, pct, charging)
        }
        return (isOnAC, nil, false)
    }

    public func isMainDisplayAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    public func snapshot(passwordlessSudoReady: Bool) -> PowerGuardTelemetry {
        var t = PowerGuardTelemetry()
        let root = readRootDomainState()
        let pwr = readPowerSource()
        t.lidClosed = root.lidClosed
        t.sleepDisabledKernel = root.sleepDisabled
        t.displayAsleep = isMainDisplayAsleep()
        t.isOnACPower = pwr.isOnAC
        t.batteryPercentage = pwr.percentage
        t.isCharging = pwr.isCharging
        t.builtInBrightness = DisplayBlackoutEngine.shared.readBrightness()
        t.isPasswordlessSudoReady = passwordlessSudoReady
        t.hardwareModel = cachedHardwareModel
        t.osVersion = cachedOSVersion
        return t
    }

    public func startObserving(onChange: @escaping @Sendable () -> Void) {
        lock.withLock {
            stopObservingLocked()
            onChangeHandler = onChange

            // 1. IOPMrootDomain interest notification (lid open/close, SleepDisabled transitions)
            let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            if rootDomain != 0 {
                defer { IOObjectRelease(rootDomain) }
                if let port = IONotificationPortCreate(kIOMainPortDefault) {
                    IONotificationPortSetDispatchQueue(port, DispatchQueue.global(qos: .utility))
                    let refcon = Unmanaged.passUnretained(self).toOpaque()
                    var notification: io_object_t = 0
                    let kr = IOServiceAddInterestNotification(
                        port,
                        rootDomain,
                        kIOGeneralInterest,
                        { refcon, _, _, _ in
                            guard let refcon else { return }
                            let probe = Unmanaged<HardwarePowerProbe>.fromOpaque(refcon).takeUnretainedValue()
                            probe.emitChange()
                        },
                        refcon,
                        &notification
                    )
                    if kr == kIOReturnSuccess {
                        notifyPort = port
                        rootDomainInterest = notification
                    } else {
                        IONotificationPortDestroy(port)
                    }
                }
            }

            // 2. IOPS power source runloop notification (AC attach/detach, battery % changes)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            if let source = IOPSNotificationCreateRunLoopSource({ refcon in
                guard let refcon else { return }
                let probe = Unmanaged<HardwarePowerProbe>.fromOpaque(refcon).takeUnretainedValue()
                probe.emitChange()
            }, refcon)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                powerSourceRunLoopSource = source
            }
        }
    }

    public func stopObserving() {
        lock.withLock { stopObservingLocked() }
    }

    private func stopObservingLocked() {
        onChangeHandler = nil
        if rootDomainInterest != 0 {
            IOObjectRelease(rootDomainInterest)
            rootDomainInterest = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceRunLoopSource = nil
        }
    }

    private func emitChange() {
        let handler = lock.withLock { onChangeHandler }
        handler?()
    }

    /// Forces system sleep if the MacBook lid is closed after disablesleep was released,
    /// since macOS only evaluates lid-close sleep on edge transitions.
    public func enforceLidSleepIfClosed(maxAttempts: Int = 6) {
        DispatchQueue.global(qos: .utility).async {
            for attempt in 0..<maxAttempts {
                let root = self.readRootDomainState()
                guard root.lidClosed, !root.sleepDisabled else { return }
                let domain = IOPMFindPowerManagement(kIOMainPortDefault)
                if domain != 0 {
                    let kr = IOPMSleepSystem(domain)
                    IOServiceClose(domain)
                    if kr == kIOReturnSuccess { return }
                }
                if attempt + 1 < maxAttempts {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        if let nul = buffer.firstIndex(of: 0) {
            return String(decoding: buffer[..<nul], as: UTF8.self)
        }
        return String(decoding: buffer, as: UTF8.self)
    }
}
