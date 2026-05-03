import Foundation

/// `debug_time_typecheck`: type-check Swift inputs with `-Xfrontend -debug-time-function-bodies`
/// and `-Xfrontend -debug-time-expression-type-checking` enabled, then return type-check
/// timings parsed from stderr.
///
/// On current swiftc the dominant signal comes from `-debug-time-function-bodies`, which
/// emits one stderr line per function declaration in the form
/// `<ms>ms\t<file>:<line>:<col>\t<decl-locator>`. The expression flag is passed through
/// for forward/backward compatibility — when active it adds 2-field lines
/// (`<ms>ms\t<file>:<line>:<col>`) which the parser also accepts. Compiler errors do
/// not fail the tool: timings are emitted regardless of compile success and the
/// diagnostics themselves are part of the analysis output. See `find_slow_typecheck`
/// for the complementary per-expression threshold variant (`-warn-long-*`).
public struct DebugTimeTypecheckTool: MCPTool {
    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let totalEntries: Int
        public let returnedEntries: Int
        public let totalMs: Double
        public let byKind: [String: Int]
        public let topEntries: [DebugTimeEntry]
        public let compilerExitCode: Int32
        public let compilerStderr: String?
    }

    private let invocation: SwiftcInvocation
    private let resolver: BuildArgsResolver
    private let parser = DebugTimeParser()

    public init(toolchain: ToolchainResolver, resolver: BuildArgsResolver = DefaultBuildArgsResolver()) {
        self.invocation = SwiftcInvocation(resolver: toolchain)
        self.resolver = resolver
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "debug_time_typecheck",
            title: "Debug-time Type-check",
            description: """
            Type-check Swift inputs with `-Xfrontend -debug-time-function-bodies` and \
            `-Xfrontend -debug-time-expression-type-checking` enabled, then parse stderr \
            into type-check timing entries. Returns the top-N entries by duration plus \
            per-kind counts and total milliseconds. The parser handles both 3-field \
            function-body lines (kind=function — the dominant signal in current swiftc) \
            and 2-field expression lines (kind=expression — emitted when the frontend \
            populates per-expression timings). Compiler errors do not fail the tool — \
            `compilerExitCode` reports the swiftc exit status. Use this tool for the full \
            timing distribution; see `find_slow_typecheck` for threshold-based per-expression \
            warnings.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "input": BuildInput.jsonSchemaProperty,
                    "top": .object([
                        "type": .string("integer"),
                        "description": .string("How many top entries to return, sorted by duration descending. Default 50."),
                        "default": .integer(50)
                    ]),
                    "min_ms": .object([
                        "type": .string("number"),
                        "description": .string("Drop entries whose durationMs is strictly below this threshold. Default 0 (keep all)."),
                        "default": .double(0)
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
        let topN = max(0, dict["top"]?.asInt ?? 50)
        let minMs: Double = {
            switch dict["min_ms"] {
            case .integer(let v): return Double(v)
            case .double(let v): return v
            default: return 0
            }
        }()

        let resolved = try await resolver.resolveArgs(for: input)

        let start = Date()
        let outcome = try await invocation.run(
            modeArgs: [
                "-typecheck",
                "-Xfrontend", "-debug-time-function-bodies",
                "-Xfrontend", "-debug-time-expression-type-checking"
            ],
            inputFiles: resolved.inputFiles,
            outputFile: nil,
            options: .init(resolved: resolved)
        )
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let stderr = outcome.process.standardError
        let allEntries = parser.parse(stderr)
        let filtered = minMs > 0 ? allEntries.filter { $0.durationMs >= minMs } : allEntries
        let sortedDescending = filtered.sorted { $0.durationMs > $1.durationMs }
        let topEntries = Array(sortedDescending.prefix(topN))

        let nonTimingStderr = stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { DebugTimeEntry(line: String($0)) == nil }
            .joined(separator: "\n")

        var byKind: [String: Int] = [:]
        for entry in filtered {
            byKind[entry.kind, default: 0] += 1
        }
        let totalMs = filtered.reduce(0.0) { $0 + $1.durationMs }

        let result = Result(
            meta: .init(
                toolchain: .init(path: outcome.toolchain.swiftcPath, version: outcome.toolchain.version),
                target: input.target,
                durationMs: durationMs
            ),
            totalEntries: filtered.count,
            returnedEntries: topEntries.count,
            totalMs: totalMs,
            byKind: byKind,
            topEntries: topEntries,
            compilerExitCode: outcome.process.exitCode,
            compilerStderr: nonTimingStderr.isEmpty ? nil : nonTimingStderr
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }
}
