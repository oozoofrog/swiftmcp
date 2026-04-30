import Foundation

/// `find_slow_typecheck`: type-check a Swift file with slow-typecheck warnings enabled,
/// then return parsed warnings as findings.
///
/// Calls `swiftc -typecheck -Xfrontend -warn-long-expression-type-checking=<n>
/// -Xfrontend -warn-long-function-bodies=<n> <file>`. Warnings emitted by the compiler
/// are extracted from stderr regardless of the compile exit status — compile errors
/// are surfaced via `compilerExitCode` rather than `isError`, since compiler
/// diagnostics are themselves the analysis output.
public struct FindSlowTypecheckTool: MCPTool {
    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let findings: [CompilerWarning]
        public let compilerExitCode: Int32
    }

    private let toolchain: ToolchainResolver
    private let parser = WarningParser()

    public init(toolchain: ToolchainResolver) {
        self.toolchain = toolchain
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "find_slow_typecheck",
            title: "Find Slow Type-checking",
            description: """
            Type-check a Swift source file with `-warn-long-expression-type-checking` and \
            `-warn-long-function-bodies` enabled, then return any expression / function \
            bodies that exceeded the given thresholds (in milliseconds). Compiler errors \
            do not fail the tool — `compilerExitCode` reports the swiftc exit status while \
            `findings` reports the long-typecheck warnings parsed from stderr.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "file": .object([
                        "type": .string("string"),
                        "description": .string("Path to a Swift source file (absolute or relative to CWD).")
                    ]),
                    "expression_threshold_ms": .object([
                        "type": .string("integer"),
                        "description": .string("Warn on expressions whose type-checking takes more than this many milliseconds. Default 100."),
                        "default": .integer(100)
                    ]),
                    "function_threshold_ms": .object([
                        "type": .string("integer"),
                        "description": .string("Warn on function bodies whose type-checking takes more than this many milliseconds. Default 100."),
                        "default": .integer(100)
                    ])
                ]),
                "required": .array([.string("file")])
            ])
        )
    }

    public func call(arguments: JSONValue?) async throws -> CallToolResult {
        guard case .object(let dict) = arguments,
              let file = dict["file"]?.asString, !file.isEmpty
        else {
            throw MCPError.invalidParams("`file` argument is required and must be a non-empty string")
        }
        let expressionThreshold = dict["expression_threshold_ms"]?.asInt ?? 100
        let functionThreshold = dict["function_threshold_ms"]?.asInt ?? 100

        let resolved = try await toolchain.resolve()

        let start = Date()
        let processResult = try await runProcess(
            executable: resolved.swiftcPath,
            arguments: [
                "-typecheck",
                "-Xfrontend", "-warn-long-expression-type-checking=\(expressionThreshold)",
                "-Xfrontend", "-warn-long-function-bodies=\(functionThreshold)",
                file
            ]
        )
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let findings = parser.parse(processResult.standardError)

        let result = Result(
            meta: .init(
                toolchain: .init(path: resolved.swiftcPath, version: resolved.version),
                target: nil,
                durationMs: durationMs
            ),
            findings: findings,
            compilerExitCode: processResult.exitCode
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }
}
