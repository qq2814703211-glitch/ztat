// SPDX-License-Identifier: GPL-3.0-or-later
// Deadlock-free child-process runner for ZtatCleaner.
//
// Reading a Pipe only after `waitUntilExit()` deadlocks as soon as the child writes more
// than the kernel pipe buffer (~64 KB): the child blocks on write, the parent blocks on
// exit. `lsbom` on a large receipt, `pip list`, `launchctl list` and `brew --zap` all
// routinely exceed that, so every engine goes through this runner, which drains stdout
// and stderr concurrently while the process runs.

import Darwin
import Foundation

enum CleanerProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var succeeded: Bool { status == 0 }
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
        /// stdout followed by stderr, trimmed — for user-facing console/log text.
        var combinedTrimmed: String {
            let parts = [stdoutString, stderrString]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return parts.joined(separator: "\n")
        }
    }

    /// Runs `executable` synchronously on the calling (background) thread.
    /// Never call from the main thread.
    static func run(_ executable: String,
                    _ arguments: [String],
                    environment: [String: String]? = nil) throws -> Output {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let environment { proc.environment = environment }
        proc.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        // Drain stderr on a helper thread while this thread drains stdout.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        proc.waitUntilExit()

        return Output(status: proc.terminationStatus, stdout: outData, stderr: errBox.data)
    }

    /// Runs `executable` asynchronously on a detached worker with an optional wall-clock timeout.
    /// Supports Swift Task cancellation and terminates the child process on timeout or cancel.
    static func runAsync(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = 25
    ) async throws -> Output {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let environment { proc.environment = environment }
        proc.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let box = AsyncRunBox()

        let worker = Task.detached(priority: .utility) { () throws -> Output in
            if Task.isCancelled {
                return Output(status: 130, stdout: Data(), stderr: Data())
            }
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                box.appendOut(chunk)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                box.appendErr(chunk)
            }

            try proc.run()

            var timer: DispatchSourceTimer?
            if let timeout, timeout > 0 {
                let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                source.schedule(deadline: .now() + timeout)
                source.setEventHandler {
                    guard proc.isRunning else { return }
                    box.markTimedOut()
                    proc.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                        if proc.isRunning {
                            kill(proc.processIdentifier, SIGKILL)
                        }
                    }
                }
                source.resume()
                timer = source
            }

            proc.waitUntilExit()
            timer?.cancel()

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let tailOut = outPipe.fileHandleForReading.readDataToEndOfFile()
            let tailErr = errPipe.fileHandleForReading.readDataToEndOfFile()
            box.appendOut(tailOut)
            box.appendErr(tailErr)

            let snapshot = box.snapshot()
            let status: Int32 = snapshot.timedOut ? 124 : proc.terminationStatus
            return Output(status: status, stdout: snapshot.out, stderr: snapshot.err)
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            if proc.isRunning {
                proc.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                    if proc.isRunning {
                        kill(proc.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }

    /// Resolves a CLI tool name across standard macOS, Homebrew, and user toolchain bin directories.
    static func resolveExecutable(_ name: String) -> String? {
        let fm = FileManager.default
        if name.hasPrefix("/") {
            return fm.isExecutableFile(atPath: name) ? name : nil
        }
        let home = (NSHomeDirectory() as NSString).standardizingPath
        let searchDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            (home as NSString).appendingPathComponent(".local/bin"),
            (home as NSString).appendingPathComponent(".cargo/bin"),
            (home as NSString).appendingPathComponent(".bun/bin"),
            (home as NSString).appendingPathComponent(".orbstack/bin")
        ]
        for dir in searchDirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    private final class AsyncRunBox: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var timedOut = false

        func appendOut(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            out.append(chunk)
            lock.unlock()
        }

        func appendErr(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            err.append(chunk)
            lock.unlock()
        }

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }

        func snapshot() -> (out: Data, err: Data, timedOut: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (out, err, timedOut)
        }
    }
}
