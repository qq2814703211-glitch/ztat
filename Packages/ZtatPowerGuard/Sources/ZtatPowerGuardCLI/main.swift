// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.pwr_mgt
import ZtatCore
import ZtatPowerGuard

private func printUsage() {
    print("""
    ztat-hold \(ZtatBrand.version) — Remote-ready keep-awake, clamshell lock & physical 0% blackout CLI

    Usage:
      ztat-hold status                 Show hardware lid, kernel SleepDisabled, battery & brightness
      ztat-hold on [--daemon]          Enable clamshell lock + keep-awake (--daemon holds IOKit assertions until Ctrl-C)
      ztat-hold off                    Disable clamshell lock & restore display brightness
      ztat-hold blackout on|off        Toggle physical 0% backlight blackout (keeps GPU/remote alive)
      ztat-hold wake                   Trigger display framebuffer user-activity wake
      ztat-hold install-sudoers        Configure least-privilege passwordless pmset rule (#uid)
      ztat-hold remove-sudoers         Remove passwordless pmset rule
      ztat-hold version                Print version
    """)
}

private func printStatus() {
    let sudoReady = ClamshellSudoEngine.shared.probePasswordlessSudoSync()
    let t = HardwarePowerProbe.shared.snapshot(passwordlessSudoReady: sudoReady)
    let brightnessStr = t.builtInBrightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "N/A"
    let battStr = t.batteryPercentage.map { "\($0)% (\(t.isOnACPower ? "AC" : "Battery"))" } ?? "AC Desktop"
    print("ztat-hold \(ZtatBrand.version) | \(t.osVersion) (\(t.hardwareModel))")
    print("  Lid Closed           : \(t.lidClosed ? "YES" : "NO")")
    print("  Kernel SleepDisabled : \(t.sleepDisabledKernel ? "YES (clamshell locked)" : "NO (default)")")
    print("  Display Asleep       : \(t.displayAsleep ? "YES" : "NO")")
    print("  Built-in Backlight   : \(brightnessStr)")
    print("  Power / Battery      : \(battStr)")
    print("  Passwordless pmset   : \(t.isPasswordlessSudoReady ? "READY" : "NOT INSTALLED")")
}

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "status"

switch cmd {
case "status":
    printStatus()

case "version", "-v", "--version":
    print("ztat-hold \(ZtatBrand.version)")

case "on", "enable", "start":
    let daemon = args.contains("--daemon") || args.contains("-d")
    let res = ClamshellSudoEngine.shared.setSleepDisabledSync(true)
    if !res.success {
        fputs("Error enabling clamshell lock: \(res.error ?? "unknown")\n", stderr)
        exit(1)
    }
    DisplayBlackoutEngine.shared.renewFramebufferWakeAssertion()
    if daemon {
        var sysID: IOPMAssertionID = 0
        var dispID: IOPMAssertionID = 0
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "ztat-hold daemon system" as CFString, &sysID)
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "ztat-hold daemon display" as CFString, &dispID)
        print("ztat-hold daemon active (clamshell locked + IOKit assertions). Press Ctrl-C to restore.")
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let capturedSysID = sysID
        let capturedDispID = dispID
        let cleanup: @Sendable () -> Void = {
            if capturedSysID != 0 { IOPMAssertionRelease(capturedSysID) }
            if capturedDispID != 0 { IOPMAssertionRelease(capturedDispID) }
            DisplayBlackoutEngine.shared.releaseFramebufferWakeAssertion()
            _ = ClamshellSudoEngine.shared.setSleepDisabledSync(false)
            print("\nRestored default macOS sleep policy.")
            exit(0)
        }
        let s1 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let s2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        s1.setEventHandler(handler: cleanup)
        s2.setEventHandler(handler: cleanup)
        s1.resume()
        s2.resume()
        let keepAlive = DispatchSource.makeTimerSource(queue: .main)
        keepAlive.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(3))
        keepAlive.setEventHandler {
            DisplayBlackoutEngine.shared.renewFramebufferWakeAssertion()
        }
        keepAlive.resume()
        dispatchMain()
    } else {
        print("Clamshell lock enabled (pmset disablesleep 1).")
    }

case "off", "disable", "stop":
    _ = DisplayBlackoutEngine.shared.disableBlackout(retryOnFailure: false)
    DisplayBlackoutEngine.shared.releaseFramebufferWakeAssertion()
    let res = ClamshellSudoEngine.shared.setSleepDisabledSync(false)
    if !res.success {
        fputs("Error disabling clamshell lock: \(res.error ?? "unknown")\n", stderr)
        exit(1)
    }
    HardwarePowerProbe.shared.enforceLidSleepIfClosed(maxAttempts: 2)
    print("Restored default macOS sleep policy.")

case "blackout", "dim":
    let sub = args.dropFirst().first ?? "on"
    if sub == "off" || sub == "0" {
        let ok = DisplayBlackoutEngine.shared.disableBlackout(retryOnFailure: false)
        print(ok ? "Restored built-in display brightness." : "Failed to restore brightness.")
        exit(ok ? 0 : 1)
    } else {
        let ok = DisplayBlackoutEngine.shared.enableBlackout()
        print(ok ? "Physical blackout enabled (0% backlight)." : "Failed to set backlight to 0%.")
        exit(ok ? 0 : 1)
    }

case "wake":
    DisplayBlackoutEngine.shared.renewFramebufferWakeAssertion()
    print("Framebuffer wake activity declared.")

case "install-sudoers":
    let res = ClamshellSudoEngine.shared.installPasswordlessSudoersSync()
    if res.success {
        print("Installed least-privilege sudoers rule at \(ClamshellSudoEngine.sudoersPath).")
    } else {
        fputs("Failed: \(res.error ?? "unknown")\n", stderr)
        exit(1)
    }

case "remove-sudoers":
    let res = ClamshellSudoEngine.shared.removePasswordlessSudoersSync()
    if res.success {
        print("Removed \(ClamshellSudoEngine.sudoersPath).")
    } else {
        fputs("Failed: \(res.error ?? "unknown")\n", stderr)
        exit(1)
    }

default:
    printUsage()
}
