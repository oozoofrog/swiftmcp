import Foundation

/// `concurrency_audit`: type-check a Swift file with strict-concurrency enabled and
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

    private let toolchain: ToolchainResolver
    private let parser = DiagnosticParser()

    public init(toolchain: ToolchainResolver) {
        self.toolchain = toolchain
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "concurrency_audit",
            title: "Concurrency Audit",
            description: """
            Type-check a Swift source file with `-strict-concurrency=<level> -warn-concurrency` \
            and classify the resulting diagnostics by `[#Group]` suffix + severity. Useful as a \
            first-pass triage for Swift 6 migration: counts of Sendable / actor-isolation / \
            concurrency violations grouped for at-a-glance scanning, with the per-finding \
            location preserved. Compiler errors are surfaced via `compilerExitCode` rather than \
            `isError` (per the channel-mapping policy: diagnostics ARE the analysis output).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "file": .object([
                        "type": .string("string"),
                        "description": .string("Path to a Swift source file.")
                    ]),
                    "level": .object([
                        "type": .string("string"),
                        "description": .string("`-strict-concurrency=` value: `minimal`, `targeted`, or `complete`. Default `complete`."),
                        "default": .string("complete")
                    ]),
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Optional target triple.")
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
        let level = dict["level"]?.asString ?? "complete"
        guard ["minimal", "targeted", "complete"].contains(level) else {
            throw MCPError.invalidParams("`level` must be one of: minimal, targeted, complete")
        }
        let target = dict["target"]?.asString

        let resolved = try await toolchain.resolve()

        var arguments: [String] = [
            "-typecheck",
            "-strict-concurrency=\(level)",
            "-warn-concurrency"
        ]
        if let target {
            arguments.append(contentsOf: ["-target", target])
        }
        arguments.append(file)

        let start = Date()
        let processResult = try await runProcess(
            executable: resolved.swiftcPath,
            arguments: arguments
        )
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let findings = parser.parse(processResult.standardError)
        let summary = makeSummary(findings: findings)

        let result = Result(
            meta: .init(
                toolchain: .init(path: resolved.swiftcPath, version: resolved.version),
                target: target,
                durationMs: durationMs
            ),
            summary: summary,
            findings: findings,
            compilerExitCode: processResult.exitCode,
            compilerStderr: processResult.standardError.isEmpty ? nil : processResult.standardError
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
