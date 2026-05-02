import Foundation

/// `concurrency_audit`: type-check Swift inputs with strict-concurrency enabled and
/// classify the resulting diagnostics by group + severity. Group identifiers come from
/// swiftc's `[#GroupName]` suffix (e.g. `SendableClosureCaptures`); diagnostics with no
/// group land under `(unknown)` so the per-group sums always match `totalFindings`.
public struct ConcurrencyAuditTool: MCPTool {
    public struct Summary: Sendable, Codable, Equatable {
        public let totalFindings: Int
        public let byGroup: [String: Int]
        public let bySeverity: [String: Int]
    }

    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let summary: Summary
        public let findings: [CompilerDiagnostic]
        public let compilerExitCode: Int32
        public let compilerStderr: String?
    }

    private let invocation: SwiftcInvocation
    private let resolver: BuildArgsResolver
    private let parser = DiagnosticParser()

    public init(toolchain: ToolchainResolver, resolver: BuildArgsResolver = DefaultBuildArgsResolver()) {
        self.invocation = SwiftcInvocation(resolver: toolchain)
        self.resolver = resolver
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "concurrency_audit",
            title: "Concurrency Audit",
            description: """
            Type-check Swift inputs with `-strict-concurrency=<level> -warn-concurrency` \
            and classify the resulting diagnostics by `[#Group]` suffix + severity. Useful as a \
            first-pass triage for Swift 6 migration: counts of Sendable / actor-isolation / \
            concurrency violations grouped for at-a-glance scanning, with the per-finding \
            location preserved. Compiler errors are surfaced via `compilerExitCode` rather than \
            `isError` (per the channel-mapping policy: diagnostics ARE the analysis output).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "input": BuildInput.jsonSchemaProperty,
                    "level": .object([
                        "type": .string("string"),
                        "description": .string("`-strict-concurrency=` value: `minimal`, `targeted`, or `complete`. Default `complete`."),
                        "default": .string("complete")
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
        let level = dict["level"]?.asString ?? "complete"
        guard ["minimal", "targeted", "complete"].contains(level) else {
            throw MCPError.invalidParams("`level` must be one of: minimal, targeted, complete")
        }

        let resolved = try await resolver.resolveArgs(for: input)

        let start = Date()
        let outcome = try await invocation.run(
            modeArgs: [
                "-typecheck",
                "-strict-concurrency=\(level)",
                "-warn-concurrency"
            ],
            inputFiles: resolved.inputFiles,
            outputFile: nil,
            options: .init(resolved: resolved)
        )
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let findings = parser.parse(outcome.process.standardError)
        let summary = makeSummary(findings: findings)

        let result = Result(
            meta: .init(
                toolchain: .init(path: outcome.toolchain.swiftcPath, version: outcome.toolchain.version),
                target: input.target,
                durationMs: durationMs
            ),
            summary: summary,
            findings: findings,
            compilerExitCode: outcome.process.exitCode,
            compilerStderr: outcome.process.standardError.isEmpty ? nil : outcome.process.standardError
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }

    private func makeSummary(findings: [CompilerDiagnostic]) -> Summary {
        var byGroup: [String: Int] = [:]
        var bySeverity: [String: Int] = [:]
        for finding in findings {
            let groupKey = finding.group ?? "(unknown)"
            byGroup[groupKey, default: 0] += 1
            bySeverity[finding.severity, default: 0] += 1
        }
        return Summary(
            totalFindings: findings.count,
            byGroup: byGroup,
            bySeverity: bySeverity
        )
    }
}
