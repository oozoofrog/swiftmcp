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

/// Side channel for delivering parent-task cancellation into the detached process-running
/// task. Modeled as an `actor` to keep all state mutation serialized — this project does
/// not use `NSLock` / `os_unfair_lock` / atomics; concurrency safety is purely via actor
/// isolation.
///
/// `markCancelled()` and `set()` interlock so a cancel arriving *before* the child is
/// even spawned still results in SIGTERM the moment the pid is registered. Without that
/// sticky flag, a heavily loaded executor can let the parent's cancel fire while
/// `Task.detached` is still queued — `onCancel` then sees pid=0, the signal vanishes,
/// and the child runs to natural completion.
///
/// `onCancel` closures are synchronous (cannot await an actor). We bridge by spawning an
/// unstructured `Task` from inside `onCancel` that awaits the actor. This adds a tiny
/// scheduling delay but is `lock`-free; SIGTERM still reaches the child well before the
/// child's own wall-clock or natural exit.
actor PIDHolder {
    private var pid: pid_t = 0
    private var cancelled: Bool = false

    /// Register the pid of a freshly-spawned child. If a cancel was already delivered
    /// (race with `onCancel` firing before this call), immediately raise SIGTERM.
    func set(_ value: pid_t) {
        pid = value
        if cancelled && value > 0 {
            #if canImport(Darwin)
            kill(value, SIGTERM)
            #endif
        }
    }

    func clear() {
        pid = 0
        // We deliberately don't reset `cancelled`; the holder is per-call and the
        // cancellation state is sticky for the lifetime of the run.
    }

    /// Mark the call as cancelled. If the child is already running, signal it; otherwise
    /// the eventual `set()` will pick up the pending cancel and signal the child as soon
    /// as it becomes addressable.
    func markCancelled() {
        cancelled = true
        if pid > 0 {
            #if canImport(Darwin)
            kill(pid, SIGTERM)
            #endif
        }
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

            await holder.set(process.processIdentifier)
            defer {
                Task { await holder.clear() }
            }

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
        // onCancel is synchronous and cannot await an actor. Spawn an unstructured Task
        // that delivers the cancel to the holder. The Task's body awaits markCancelled
        // — by then either the child is running (immediate SIGTERM) or set() will
        // observe the sticky cancelled flag when the spawn finally lands.
        Task { await holder.markCancelled() }
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

            await holder.set(process.processIdentifier)
            defer {
                Task { await holder.clear() }
            }

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
        // See note in runProcess: onCancel is synchronous; we hop into the actor via an
        // unstructured Task.
        Task { await holder.markCancelled() }
    }
}
