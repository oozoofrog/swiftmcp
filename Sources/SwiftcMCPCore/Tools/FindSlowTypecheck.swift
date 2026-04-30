import Foundation

/// `find_slow_typecheck`: type-check Swift inputs with slow-typecheck warnings enabled,
/// then return parsed warnings as findings.
///
/// Calls `swiftc -typecheck -Xfrontend -warn-long-expression-type-checking=<n>
/// -Xfrontend -warn-long-function-bodies=<n> <inputs...>`. Warnings emitted by the
/// compiler are extracted from stderr regardless of compile exit status — compile
/// errors are surfaced via `compilerExitCode` rather than `isError`, since compiler
/// diagnostics are themselves the analysis output.
public struct FindSlowTypecheckTool: MCPTool {
    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let findings: [CompilerWarning]
        public let compilerExitCode: Int32
    }

    private let invocation: SwiftcInvocation
    private let resolver: BuildArgsResolver
    private let parser = WarningParser()

    public init(toolchain: ToolchainResolver, resolver: BuildArgsResolver = DefaultBuildArgsResolver()) {
        self.invocation = SwiftcInvocation(resolver: toolchain)
        self.resolver = resolver
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "find_slow_typecheck",
            title: "Find Slow Type-checking",
            description: """
            Type-check a Swift source file or directory with `-warn-long-expression-type-checking` \
            and `-warn-long-function-bodies` enabled, then return any expression / function \
            bodies that exceeded the given thresholds (in milliseconds). Compiler errors \
            do not fail the tool — `compilerExitCode` reports the swiftc exit status while \
            `findings` reports the long-typecheck warnings parsed from stderr.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "input": BuildInput.jsonSchemaProperty,
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
                "required": .array([.string("input")])
            ])
        )
    }

    public func call(arguments: JSONValue?) async throws -> CallToolResult {
        guard case .object(let dict) = arguments else {
            throw MCPError.invalidParams("arguments must be an object")
        }
        let input = try BuildInput.decode(dict["input"])
        let expressionThreshold = dict["expression_threshold_ms"]?.asInt ?? 100
        let functionThreshold = dict["function_threshold_ms"]?.asInt ?? 100

        let resolved = try await resolver.resolveArgs(for: input)

        let start = Date()
        let outcome = try await invocation.run(
            modeArgs: [
                "-typecheck",
                "-Xfrontend", "-warn-long-expression-type-checking=\(expressionThreshold)",
                "-Xfrontend", "-warn-long-function-bodies=\(functionThreshold)"
            ],
            inputFiles: resolved.inputFiles,
            outputFile: nil,
            options: .init(resolved: resolved)
        )
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let findings = parser.parse(outcome.process.standardError)

        let result = Result(
            meta: .init(
                toolchain: .init(path: outcome.toolchain.swiftcPath, version: outcome.toolchain.version),
                target: input.target,
                durationMs: durationMs
            ),
            findings: findings,
            compilerExitCode: outcome.process.exitCode
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }
}
