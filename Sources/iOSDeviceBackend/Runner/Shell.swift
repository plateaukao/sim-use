// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Runs a subprocess to completion with a timeout.
///
/// `AndroidBackend.Adb` has an equivalent private to that target; this
/// one stays local rather than being hoisted into `SimUseCore` because
/// the two have different needs (adb's is `adb`-specific and threads a
/// serial through every call) and a shared abstraction would be wider
/// than either use.
enum Shell {
    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    enum ShellError: Error, LocalizedError {
        case launchFailed(String, String)
        case timedOut(String, TimeInterval)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let tool, let detail):
                return "Could not run \(tool): \(detail)"
            case .timedOut(let tool, let seconds):
                return "\(tool) did not finish within \(Int(seconds))s."
            }
        }
    }

    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 120
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(executable, error.localizedDescription)
        }

        // Drain both pipes concurrently. xcodebuild emits far more than
        // the 64 KB pipe buffer, so a wait-then-read ordering deadlocks:
        // the child blocks writing, the parent blocks waiting.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.linecorp.simuse.shell", attributes: .concurrent)
        let lock = NSLock()

        group.enter()
        queue.async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = data; lock.unlock()
            group.leave()
        }
        group.enter()
        queue.async {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = data; lock.unlock()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            _ = group.wait(timeout: .now() + 5)
            throw ShellError.timedOut(executable, timeout)
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 10)

        lock.lock()
        defer { lock.unlock() }
        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
