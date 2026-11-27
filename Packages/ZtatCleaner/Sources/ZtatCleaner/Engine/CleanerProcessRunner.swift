// SPDX-License-Identifier: GPL-3.0-or-later
// Deadlock-free child-process runner for ZtatCleaner.
//
// Reading a Pipe only after `waitUntilExit()` deadlocks as soon as the child writes more
// than the kernel pipe buffer (~64 KB): the child blocks on write, the parent blocks on
// exit. `lsbom` on a large receipt, `pip list`, `launchctl list` and `brew --zap` all
// routinely exceed that, so every engine goes through this runner, which drains stdout
// and stderr concurrently while the process runs.

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

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}
