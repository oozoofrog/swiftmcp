import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var standardOutputTrimmed: String {
        standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct TimedProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool
}

/// Side channel for delivering parent-task cancellation into a detached process-running task.
/// `withTaskCancellationHandler.onCancel` is sync and cannot await actors, so we hold the pid
/// behind an NSLock and signal SIGTERM directly from the cancellation handler.
final class PIDHolder: @unchecked Sendable {
    private var pid: pid_t = 0
    private let lock = NSLock()

    func set(_ value: pid_t) {
        lock.lock()
        pid = value
        lock.unlock()
    }

    func clear() {
        set(0)
    }

    func get() -> pid_t {
        lock.lock()
        defer { lock.unlock() }
        return pid
    }
}

public enum ProcessRunnerError: Error, Sendable {
    case launchFailed(String)
}

/// Run an external process to completion, capturing stdout and stderr.
/// Pipes are read on a detached task so the call doesn't block the caller's actor.
/// Parent-task cancellation is propagated to the child via SIGTERM (see `PIDHolder`).
public func runProcess(
    executable: String,
    arguments: [String],
    environment: [String: String]? = nil,
    workingDirectory: URL? = nil
) async throws -> ProcessResult {
    let holder = PIDHolder()
    return try await withTaskCancellationHandler {
        try await Task.detached { @Sendable in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment {
                process.environment = environment
            }
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                throw ProcessRunnerError.launchFailed("\(error)")
            }

            holder.set(process.processIdentifier)
            defer { holder.clear() }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return ProcessResult(
                exitCode: process.terminationStatus,
                standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
                standardError: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }.value
    } onCancel: {
        let pid = holder.get()
        if pid > 0 {
            #if canImport(Darwin)
            kill(pid, SIGTERM)
            #endif
        }
    }
}

/// Same as `runProcess` but enforces a wall-clock timeout. On expiry the process
/// receives `SIGTERM`; if it ignores the signal for 1 second we escalate to `SIGKILL`.
/// Parent-task cancellation is propagated to the child via SIGTERM (see `PIDHolder`).
public func runProcessWithTimeout(
    executable: String,
    arguments: [String],
    environment: [String: String]? = nil,
    workingDirectory: URL? = nil,
    timeout: TimeInterval
) async throws -> TimedProcessResult {
    let holder = PIDHolder()
    return try await withTaskCancellationHandler {
        try await Task.detached { @Sendable in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment {
                process.environment = environment
            }
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                throw ProcessRunnerError.launchFailed("\(error)")
            }

            holder.set(process.processIdentifier)
            defer { holder.clear() }

            let pollInterval: TimeInterval = 0.05
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
            }

            var timedOut = false
            if process.isRunning {
                timedOut = true
                process.terminate() // SIGTERM
                let graceDeadline = Date().addingTimeInterval(1.0)
                while process.isRunning && Date() < graceDeadline {
                    try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
                }
                #if canImport(Darwin)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                #endif
                process.waitUntilExit()
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            return TimedProcessResult(
                exitCode: process.terminationStatus,
                standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
                standardError: String(data: stderrData, encoding: .utf8) ?? "",
                timedOut: timedOut
            )
        }.value
    } onCancel: {
        let pid = holder.get()
        if pid > 0 {
            #if canImport(Darwin)
            kill(pid, SIGTERM)
            #endif
        }
    }
}
