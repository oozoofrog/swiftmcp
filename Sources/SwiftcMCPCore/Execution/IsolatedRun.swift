import Foundation

/// Build a synthesized Swift snippet into a standalone executable in a per-call scratch
/// directory, then run it under a wall-clock timeout. Both the build artifacts and the
/// scratch directory are cleaned up after the run.
public struct IsolatedRun: Sendable {
    public struct Outcome: Sendable {
        public let toolchain: ToolchainResolver.Resolved
        public let buildExitCode: Int32
        public let buildStderr: String
        public let runStdout: String?
        public let runStderr: String?
        public let runExitCode: Int32?
        public let runDurationMs: Int?
        public let timedOut: Bool
    }

    private let invocation: SwiftcInvocation

    public init(resolver: ToolchainResolver) {
        self.invocation = SwiftcInvocation(resolver: resolver)
    }

    public func runSnippet(
        code: String,
        target: String?,
        argv: [String],
        timeout: TimeInterval
    ) async throws -> Outcome {
        let scratch = try CallScratch()
        defer { scratch.dispose() }

        let sourceURL = try scratch.write(name: "main.swift", contents: code)
        let exeURL = scratch.directory.appending(path: "exe", directoryHint: .notDirectory)

        let buildOutcome = try await invocation.run(
            modeArgs: [],
            inputFiles: [sourceURL.path],
            outputFile: exeURL,
            options: .init(target: target, optimization: .speed)
        )

        guard buildOutcome.process.exitCode == 0 else {
            return Outcome(
                toolchain: buildOutcome.toolchain,
                buildExitCode: buildOutcome.process.exitCode,
                buildStderr: buildOutcome.process.standardError,
                runStdout: nil,
                runStderr: nil,
                runExitCode: nil,
                runDurationMs: nil,
                timedOut: false
            )
        }

        let runStart = Date()
        let runResult = try await runProcessWithTimeout(
            executable: exeURL.path,
            arguments: argv,
            timeout: timeout
        )
        let runDurationMs = Int(Date().timeIntervalSince(runStart) * 1000)

        return Outcome(
            toolchain: buildOutcome.toolchain,
            buildExitCode: 0,
            buildStderr: buildOutcome.process.standardError,
            runStdout: runResult.standardOutput,
            runStderr: runResult.standardError,
            runExitCode: runResult.exitCode,
            runDurationMs: runDurationMs,
            timedOut: runResult.timedOut
        )
    }
}
