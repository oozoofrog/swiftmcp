import Foundation

/// `build_isolated_snippet`: compile a Swift source string with `-O`, then run the
/// resulting executable under a wall-clock timeout. Returns build diagnostics +
/// run output. Compile diagnostics are reported as success per the channel-mapping
/// policy; only timeouts (and toolchain failures bubbled up as throws) are isError.
public struct BuildIsolatedSnippetTool: MCPTool {
    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let buildExitCode: Int32
        public let buildStderr: String?
        public let runStdout: String?
        public let runStderr: String?
        public let runExitCode: Int32?
        public let runDurationMs: Int?
        public let timedOut: Bool
    }

    private let isolatedRun: IsolatedRun

    public init(toolchain: ToolchainResolver) {
        self.isolatedRun = IsolatedRun(resolver: toolchain)
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "build_isolated_snippet",
            title: "Build & Run Isolated Snippet",
            description: """
            Compile a self-contained Swift source string with `-O` into a temp executable, \
            then run it with the given argv under a wall-clock timeout. Returns build \
            diagnostics, run stdout/stderr, exit code, and timing. Build failures are \
            surfaced as a successful tool result with non-zero `buildExitCode` (compiler \
            diagnostics are themselves the analysis output). Wall-clock timeouts mark \
            `timedOut: true` and `isError: true`.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("Self-contained Swift source. Should include any top-level code or @main entry point.")
                    ]),
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Optional target triple. Default: host.")
                    ]),
                    "timeout_ms": .object([
                        "type": .string("integer"),
                        "description": .string("Wall-clock timeout for the executable run (not the build). Default 10000."),
                        "default": .integer(10_000)
                    ]),
                    "args": .object([
                        "type": .string("array"),
                        "description": .string("Argv passed to the built executable.")
                    ])
                ]),
                "required": .array([.string("code")])
            ])
        )
    }

    public func call(arguments: JSONValue?) async throws -> CallToolResult {
        guard case .object(let dict) = arguments,
              let code = dict["code"]?.asString, !code.isEmpty
        else {
            throw MCPError.invalidParams("`code` argument is required and must be a non-empty string")
        }
        let target = dict["target"]?.asString
        let timeoutMs = dict["timeout_ms"]?.asInt ?? 10_000
        let argv: [String]
        if case .array(let arr) = dict["args"] {
            argv = arr.compactMap { $0.asString }
        } else {
            argv = []
        }

        let start = Date()
        let outcome = try await isolatedRun.runSnippet(
            code: code,
            target: target,
            argv: argv,
            timeout: TimeInterval(timeoutMs) / 1000.0
        )
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let result = Result(
            meta: .init(
                toolchain: .init(path: outcome.toolchain.swiftcPath, version: outcome.toolchain.version),
                target: target,
                durationMs: durationMs
            ),
            buildExitCode: outcome.buildExitCode,
            buildStderr: outcome.buildStderr.isEmpty ? nil : outcome.buildStderr,
            runStdout: outcome.runStdout,
            runStderr: outcome.runStderr,
            runExitCode: outcome.runExitCode,
            runDurationMs: outcome.runDurationMs,
            timedOut: outcome.timedOut
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: outcome.timedOut)
    }
}
