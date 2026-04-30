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

public enum ProcessRunnerError: Error, Sendable {
    case launchFailed(String)
}

/// Run an external process to completion, capturing stdout and stderr.
/// Pipes are read on a detached task so the call doesn't block the caller's actor.
public func runProcess(
    executable: String,
    arguments: [String],
    environment: [String: String]? = nil,
    workingDirectory: URL? = nil
) async throws -> ProcessResult {
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

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
            standardError: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }.value
}

/// Same as `runProcess` but enforces a wall-clock timeout. On expiry the process
/// receives `SIGTERM`; if it ignores the signal for 1 second we escalate to `SIGKILL`.
public func runProcessWithTimeout(
    executable: String,
    arguments: [String],
    environment: [String: String]? = nil,
    workingDirectory: URL? = nil,
    timeout: TimeInterval
) async throws -> TimedProcessResult {
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

        // Poll for completion; sleep in a detached task is fine.
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
}
