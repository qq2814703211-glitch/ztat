// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ZtatCore

/// Least-privilege, serialized kernel power (`pmset disablesleep`, `lowpowermode`, `powermode`, `highpowermode`)
/// and sudoers manager shared across ZtatPowerGuard, ZtatStatusTrio, and ztat-hold CLI.
/// - Scopes sudoers strictly to numeric `#<uid>` with exact literal `/usr/bin/pmset` commands (zero wildcards).
/// - Validates sudoers with `visudo -c -f` before atomic move into `/etc/sudoers.d/ztat-powerguard`.
/// - Bounds all non-interactive subprocess calls with a hard timeout so UI queues never deadlock.
public final class ClamshellSudoEngine: @unchecked Sendable {
    public static let shared = ClamshellSudoEngine()

    public static let sudoersPath = "/etc/sudoers.d/ztat-powerguard"

    private let queue = DispatchQueue(label: "dev.ztat.powerguard.pmset", qos: .userInitiated)
    private let stateLock = NSLock()
    private var cachedSudoReady: Bool?
    private var cachedClamshellSudoOnly: Bool = false
    private var cachedCapabilities: PowerModeCapabilities?

    private struct PowerModeCapabilities {
        let supportsUnifiedPowerMode: Bool
        let supportsHighPowerMode: Bool
    }

    private init() {}

    /// Exact least-privilege sudoers rule covering Clamshell Lock + Low/High Power Mode with zero wildcards.
    public var expectedRuleLine: String {
        "#\(getuid()) ALL=(root) NOPASSWD: "
            + "/usr/bin/pmset disablesleep 1, "
            + "/usr/bin/pmset disablesleep 0, "
            + "/usr/bin/pmset -a lowpowermode 1, "
            + "/usr/bin/pmset -a lowpowermode 0, "
            + "/usr/bin/pmset -a powermode 0, "
            + "/usr/bin/pmset -a powermode 1, "
            + "/usr/bin/pmset -a powermode 2, "
            + "/usr/bin/pmset -a highpowermode 0, "
            + "/usr/bin/pmset -a highpowermode 1"
    }

    public func isPasswordlessSudoReadyCached() -> Bool {
        stateLock.withLock { cachedSudoReady ?? false }
    }

    public func isClamshellSudoLegacyOnlyCached() -> Bool {
        stateLock.withLock { cachedClamshellSudoOnly }
    }

    public func refreshPasswordlessSudoStatus() async -> Bool {
        await withCheckedContinuation { cont in
            queue.async {
                let full = self.probePasswordlessSudoSync()
                let legacyOnly = !full && self.probeClamshellSudoSync()
                self.stateLock.withLock {
                    self.cachedSudoReady = full
                    self.cachedClamshellSudoOnly = legacyOnly
                }
                cont.resume(returning: full)
            }
        }
    }

    /// Probes whether the core clamshell rule (`pmset disablesleep 0`) is passwordless.
    public func probeClamshellSudoSync() -> Bool {
        let res = runProcess("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "disablesleep", "0"], timeout: 4.0)
        return res.exitCode == 0
    }

    /// Probes whether the full unified power rule (clamshell + lowpowermode + powermode) is installed.
    public func probePasswordlessSudoSync() -> Bool {
        let checks: [[String]] = [
            ["-n", "-l", "/usr/bin/pmset", "disablesleep", "0"],
            ["-n", "-l", "/usr/bin/pmset", "-a", "lowpowermode", "0"],
            ["-n", "-l", "/usr/bin/pmset", "-a", "powermode", "0"],
        ]
        for args in checks {
            let res = runProcess("/usr/bin/sudo", args, timeout: 4.0)
            if res.exitCode != 0 {
                return false
            }
        }
        return true
    }

    // MARK: - Clamshell Lock (`pmset disablesleep`)

    public func setSleepDisabled(_ disabled: Bool) async -> (success: Bool, error: String?) {
        await withCheckedContinuation { cont in
            queue.async {
                let result = self.setSleepDisabledSync(disabled)
                cont.resume(returning: result)
            }
        }
    }

    public func setSleepDisabledSync(_ disabled: Bool) -> (success: Bool, error: String?) {
        let arg = disabled ? "1" : "0"
        if disabled {
            PowerGuardDefaults.store.set(true, forKey: PowerGuardDefaultsKey.sleepDisabledOwned)
        }

        // Fast path: passwordless sudo (works for both legacy 2-command and full unified rules)
        if probeClamshellSudoSync() {
            let res = runProcess("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "disablesleep", arg], timeout: 5.0)
            if res.exitCode == 0 {
                if !disabled {
                    PowerGuardDefaults.store.removeObject(forKey: PowerGuardDefaultsKey.sleepDisabledOwned)
                }
                return (true, nil)
            }
        }

        // Fallback: authenticated AppleScript elevation
        let script = "do shell script \"/usr/bin/pmset disablesleep \(arg)\" with administrator privileges"
        let res = runProcess("/usr/bin/osascript", ["-e", script], timeout: nil)
        if res.exitCode == 0 {
            if !disabled {
                PowerGuardDefaults.store.removeObject(forKey: PowerGuardDefaultsKey.sleepDisabledOwned)
            }
            return (true, nil)
        }

        if disabled {
            PowerGuardDefaults.store.removeObject(forKey: PowerGuardDefaultsKey.sleepDisabledOwned)
        }
        let msg = res.stderr.isEmpty ? "pmset exit \(res.exitCode)" : res.stderr
        return (false, msg)
    }

    // MARK: - Unified Low / High Power Modes (`pmset -a lowpowermode` / `powermode` / `highpowermode`)

    public func readPowerModeState() async -> (lowPower: Bool, highPower: Bool, supportsHighPower: Bool) {
        await withCheckedContinuation { cont in
            queue.async {
                let state = self.readPowerModeStateSync()
                cont.resume(returning: state)
            }
        }
    }

    public func readPowerModeStateSync() -> (lowPower: Bool, highPower: Bool, supportsHighPower: Bool) {
        let caps = readCapabilitiesLocked()
        let pmsetOut = runProcess("/usr/bin/pmset", ["-g"], timeout: 3.0)
        var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        var highPower = false

        if pmsetOut.exitCode == 0 {
            for rawLine in pmsetOut.stdout.split(separator: "\n") {
                let parts = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2 else { continue }
                let key = parts[0].lowercased()
                let val = Int(parts[1])
                if key == "powermode", let val {
                    lowPower = (val == 1)
                    highPower = (val == 2)
                } else if key == "lowpowermode", let val {
                    lowPower = (val != 0)
                } else if key == "highpowermode", let val {
                    highPower = (val != 0)
                }
            }
        }

        return (lowPower, highPower, caps.supportsHighPowerMode)
    }

    public func setLowPowerMode(
        _ enabled: Bool,
        allowInteractivePrompt: Bool = true
    ) async -> (success: Bool, observed: Bool, error: String?) {
        await withCheckedContinuation { cont in
            queue.async {
                let result = self.setLowPowerModeSync(enabled, allowInteractivePrompt: allowInteractivePrompt)
                cont.resume(returning: result)
            }
        }
    }

    public func setLowPowerModeSync(
        _ enabled: Bool,
        allowInteractivePrompt: Bool = true
    ) -> (success: Bool, observed: Bool, error: String?) {
        let caps = readCapabilitiesLocked()
        let args: [String] = caps.supportsUnifiedPowerMode
            ? ["-a", "powermode", enabled ? "1" : "0"]
            : ["-a", "lowpowermode", enabled ? "1" : "0"]

        let exec = runPrivilegedPmset(args, allowInteractivePrompt: allowInteractivePrompt)
        let observed = readPowerModeStateSync().lowPower
        if exec.success {
            return (true, observed, nil)
        }
        return (false, observed, exec.error)
    }

    public func setHighPowerMode(
        _ enabled: Bool,
        allowInteractivePrompt: Bool = true
    ) async -> (success: Bool, observed: Bool, error: String?) {
        await withCheckedContinuation { cont in
            queue.async {
                let result = self.setHighPowerModeSync(enabled, allowInteractivePrompt: allowInteractivePrompt)
                cont.resume(returning: result)
            }
        }
    }

    public func setHighPowerModeSync(
        _ enabled: Bool,
        allowInteractivePrompt: Bool = true
    ) -> (success: Bool, observed: Bool, error: String?) {
        let caps = readCapabilitiesLocked()
        guard caps.supportsHighPowerMode else {
            return (false, false, ZtatL10n.tr("此 Mac 不支持高能耗模式", "High Power Mode is not supported on this Mac"))
        }
        let args: [String] = caps.supportsUnifiedPowerMode
            ? ["-a", "powermode", enabled ? "2" : "0"]
            : ["-a", "highpowermode", enabled ? "1" : "0"]

        let exec = runPrivilegedPmset(args, allowInteractivePrompt: allowInteractivePrompt)
        let observed = readPowerModeStateSync().highPower
        if exec.success {
            return (true, observed, nil)
        }
        return (false, observed, exec.error)
    }

    private func readCapabilitiesLocked() -> PowerModeCapabilities {
        if let cached = stateLock.withLock({ cachedCapabilities }) {
            return cached
        }
        let capRes = runProcess("/usr/bin/pmset", ["-g", "cap"], timeout: 3.0)
        var unified = false
        var high = false
        if capRes.exitCode == 0 {
            let lower = capRes.stdout.lowercased()
            let tokens = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            if tokens.contains("powermode") {
                unified = true
                // Check whether pmset -g cap lists powermode AND hardware supports high power (2).
                // On Macs without High Power Mode (e.g. Air), macOS may still accept powermode 0/1 while rejecting 2;
                // pmset -g cap outputs `highpowermode` explicitly on Macs that support High Power Mode, or `powermode`
                // on Apple Silicon Pro/Max/Ultra MacBooks.
                high = tokens.contains("highpowermode") || Self.detectHighPowerFromHardwareCap(capRes.stdout)
            } else if tokens.contains("highpowermode") {
                high = true
            }
        }
        let caps = PowerModeCapabilities(supportsUnifiedPowerMode: unified, supportsHighPowerMode: high)
        stateLock.withLock { cachedCapabilities = caps }
        return caps
    }

    private static func detectHighPowerFromHardwareCap(_ capOutput: String) -> Bool {
        // Look for explicit highpowermode capability or powermode on models that expose >1 mode.
        for line in capOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "highpowermode" || trimmed.hasPrefix("highpowermode ") {
                return true
            }
        }
        // Fallback: check sysctl/ioreg for HighPowerMode support on macOS 15+/26+ Apple Silicon.
        let pmsetLive = ClamshellSudoEngine.shared.runProcess("/usr/bin/pmset", ["-g"], timeout: 2.0)
        if pmsetLive.exitCode == 0 {
            for line in pmsetLive.stdout.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.hasPrefix("highpowermode") {
                    return true
                }
            }
        }
        return false
    }

    private func runPrivilegedPmset(
        _ pmsetArgs: [String],
        allowInteractivePrompt: Bool
    ) -> (success: Bool, error: String?) {
        let probeArgs = ["-n", "-l", "/usr/bin/pmset"] + pmsetArgs
        if runProcess("/usr/bin/sudo", probeArgs, timeout: 4.0).exitCode == 0 {
            let res = runProcess("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + pmsetArgs, timeout: 5.0)
            if res.exitCode == 0 {
                return (true, nil)
            }
            return (false, res.stderr.isEmpty ? "pmset exit \(res.exitCode)" : res.stderr)
        }

        guard allowInteractivePrompt else {
            return (
                false,
                ZtatL10n.tr(
                    "尚未安装免密 pmset 规则，后台自动化已跳过（请在“保活”设置中一键配置免密）",
                    "Passwordless pmset rule not installed; skipped background switch"
                )
            )
        }

        let cmd = (["/usr/bin/pmset"] + pmsetArgs).joined(separator: " ")
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        let res = runProcess("/usr/bin/osascript", ["-e", script], timeout: nil)
        if res.exitCode == 0 {
            return (true, nil)
        }
        let msg = res.stderr.isEmpty ? "pmset exit \(res.exitCode)" : res.stderr
        return (false, msg)
    }

    // MARK: - Sudoers Install / Remove

    public func installPasswordlessSudoers() async -> (success: Bool, error: String?) {
        await withCheckedContinuation { cont in
            queue.async {
                let res = self.installPasswordlessSudoersSync()
                let verified = res.success ? self.probePasswordlessSudoSync() : false
                self.stateLock.withLock {
                    self.cachedSudoReady = verified
                    self.cachedClamshellSudoOnly = !verified && self.probeClamshellSudoSync()
                }
                cont.resume(returning: res)
            }
        }
    }

    public func installPasswordlessSudoersSync() -> (success: Bool, error: String?) {
        let rule = expectedRuleLine
        let shell = """
        tmp=$(mktemp /private/tmp/ztat-sudoers.XXXXXX) && \
        trap 'rm -f "$tmp"' EXIT && \
        printf '%s\\n' '\(rule)' > "$tmp" && \
        chmod 0440 "$tmp" && \
        /usr/sbin/visudo -c -f "$tmp" >/dev/null && \
        mkdir -p /etc/sudoers.d && \
        mv -f "$tmp" '\(Self.sudoersPath)' && \
        chown root:wheel '\(Self.sudoersPath)' && \
        chmod 0440 '\(Self.sudoersPath)'
        """
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let res = runProcess("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: nil)
        if res.exitCode == 0 {
            return (true, nil)
        }
        return (false, res.stderr.isEmpty ? "sudoers install failed (\(res.exitCode))" : res.stderr)
    }

    public func removePasswordlessSudoers() async -> (success: Bool, error: String?) {
        await withCheckedContinuation { cont in
            queue.async {
                let res = self.removePasswordlessSudoersSync()
                if res.success {
                    self.stateLock.withLock {
                        self.cachedSudoReady = false
                        self.cachedClamshellSudoOnly = false
                    }
                }
                cont.resume(returning: res)
            }
        }
    }

    public func removePasswordlessSudoersSync() -> (success: Bool, error: String?) {
        let script = "do shell script \"/bin/rm -f '\(Self.sudoersPath)'\" with administrator privileges"
        let res = runProcess("/usr/bin/osascript", ["-e", script], timeout: nil)
        if res.exitCode == 0 {
            return (true, nil)
        }
        return (false, res.stderr.isEmpty ? "sudoers remove failed (\(res.exitCode))" : res.stderr)
    }

    private func runProcess(
        _ launchPath: String,
        _ args: [String],
        timeout: TimeInterval?
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        if let timeout {
            if done.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                _ = done.wait(timeout: .now() + 0.5)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                return (-2, "", "Command timed out after \(Int(timeout))s")
            }
        } else {
            done.wait()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}
