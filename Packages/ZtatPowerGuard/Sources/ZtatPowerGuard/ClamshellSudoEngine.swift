// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ZtatCore

/// Least-privilege, serialized kernel clamshell (`pmset disablesleep`) & sudoers manager.
/// - Scopes sudoers strictly to `#<uid> ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0`.
/// - Validates sudoers with `visudo -c -f` before moving into `/etc/sudoers.d/ztat-powerguard`.
/// - Runs all subprocesses asynchronously off the main thread with serialized locking (zero UI stalls).
public final class ClamshellSudoEngine: @unchecked Sendable {
    public static let shared = ClamshellSudoEngine()

    public static let sudoersPath = "/etc/sudoers.d/ztat-powerguard"

    private let queue = DispatchQueue(label: "dev.ztat.powerguard.pmset", qos: .userInitiated)
    private let stateLock = NSLock()
    private var cachedSudoReady: Bool?

    private init() {}

    public var expectedRuleLine: String {
        "#\(getuid()) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
    }

    public func isPasswordlessSudoReadyCached() -> Bool {
        stateLock.withLock { cachedSudoReady ?? false }
    }

    public func refreshPasswordlessSudoStatus() async -> Bool {
        let ready: Bool = await withCheckedContinuation { cont in
            queue.async {
                let ok = self.probePasswordlessSudoSync()
                self.stateLock.withLock { self.cachedSudoReady = ok }
                cont.resume(returning: ok)
            }
        }
        return ready
    }

    public func probePasswordlessSudoSync() -> Bool {
        // Test specifically against one of our exact whitelisted commands via `sudo -n -l`
        let res = runProcess("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "disablesleep", "0"])
        return res.exitCode == 0
    }

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
            UserDefaults.standard.set(true, forKey: PowerGuardDefaultsKey.sleepDisabledOwned)
        }

        // Fast path: passwordless sudo
        if probePasswordlessSudoSync() {
            stateLock.withLock { cachedSudoReady = true }
            let res = runProcess("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "disablesleep", arg])
            if res.exitCode == 0 {
                if !disabled {
                    UserDefaults.standard.removeObject(forKey: PowerGuardDefaultsKey.sleepDisabledOwned)
                }
                return (true, nil)
            }
        }

        // Fallback: authenticated AppleScript elevation
        let script = "do shell script \"/usr/bin/pmset disablesleep \(arg)\" with administrator privileges"
        let res = runProcess("/usr/bin/osascript", ["-e", script])
        if res.exitCode == 0 {
            if !disabled {
                UserDefaults.standard.removeObject(forKey: PowerGuardDefaultsKey.sleepDisabledOwned)
            }
            return (true, nil)
        }

        if disabled {
            UserDefaults.standard.removeObject(forKey: PowerGuardDefaultsKey.sleepDisabledOwned)
        }
        let msg = res.stderr.isEmpty ? "pmset exit \(res.exitCode)" : res.stderr
        return (false, msg)
    }

    public func installPasswordlessSudoers() async -> (success: Bool, error: String?) {
        await withCheckedContinuation { cont in
            queue.async {
                let res = self.installPasswordlessSudoersSync()
                self.stateLock.withLock { self.cachedSudoReady = res.success }
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
        let res = runProcess("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
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
                    self.stateLock.withLock { self.cachedSudoReady = false }
                }
                cont.resume(returning: res)
            }
        }
    }

    public func removePasswordlessSudoersSync() -> (success: Bool, error: String?) {
        let script = "do shell script \"/bin/rm -f '\(Self.sudoersPath)'\" with administrator privileges"
        let res = runProcess("/usr/bin/osascript", ["-e", script])
        if res.exitCode == 0 {
            return (true, nil)
        }
        return (false, res.stderr.isEmpty ? "sudoers remove failed (\(res.exitCode))" : res.stderr)
    }

    private func runProcess(_ launchPath: String, _ args: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }
}
