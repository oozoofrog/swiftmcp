import Foundation

/// `compile_stats`: type-check a Swift file with `-stats-output-dir` and aggregate the
/// frontend stats JSON. Returns top-N counters by raw value plus per-category sums for
/// hot-spot analysis. Categories are the dotted prefix of each counter
/// (`AST`, `Parse`, `Sema`, `IRGen`, `LLVM`, `SIL`, `Frontend`, …).
public struct CompileStatsTool: MCPTool {
    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let totalCounters: Int
        public let topCounters: [Counter]
        public let byCategory: [String: Int64]
        public let compilerExitCode: Int32
        public let compilerStderr: String?

        public struct Counter: Sendable, Codable, Equatable {
            public let name: String
            public let value: Int64
        }
    }

    private let invocation: SwiftcInvocation

    public init(toolchain: ToolchainResolver) {
        self.invocation = SwiftcInvocation(resolver: toolchain)
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "compile_stats",
            title: "Compile Stats",
            description: """
            Type-check a Swift file with `-stats-output-dir <dir>` and aggregate the frontend
            stats JSON. Each compilation emits ~100 counters across categories like AST, Parse, \
            Sema, IRGen, LLVM, SIL. The result includes top-N counters by raw value and a \
            per-category sum useful for spotting hot areas (e.g. solver explosions show up in \
            `Sema.*`, IR generation slowdowns in `IRGen.*`/`LLVM.*`).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "file": .object([
                        "type": .string("string"),
                        "description": .string("Path to a Swift source file.")
                    ]),
                    "top": .object([
                        "type": .string("integer"),
                        "description": .string("How many top counters to return. Default 20."),
                        "default": .integer(20)
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
        let topN = dict["top"]?.asInt ?? 20
        let target = dict["target"]?.asString

        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let statsDir = scratch.directory.appending(path: "stats", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: statsDir, withIntermediateDirectories: true)

        let start = Date()
        let outcome = try await invocation.run(
            modeArgs: ["-typecheck", "-stats-output-dir", statsDir.path],
            inputFile: file,
            outputFile: nil,
            options: .init(target: target)
        )
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let counters = readAllCounters(statsDir: statsDir)
        let sortedDescending = counters.sorted { $0.value > $1.value }
        let topCounters = Array(sortedDescending.prefix(max(0, topN)))
        let byCategory = aggregateByCategory(counters: counters)

        let result = Result(
            meta: .init(
                toolchain: .init(path: outcome.toolchain.swiftcPath, version: outcome.toolchain.version),
                target: target,
                durationMs: durationMs
            ),
            totalCounters: counters.count,
            topCounters: topCounters,
            byCategory: byCategory,
            compilerExitCode: outcome.process.exitCode,
            compilerStderr: outcome.process.standardError.isEmpty ? nil : outcome.process.standardError
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }

    private func readAllCounters(statsDir: URL) -> [Result.Counter] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: statsDir,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
        } catch {
            return []
        }

        var merged: [String: Int64] = [:]
        for fileURL in files {
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            guard let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { continue }
            for (key, value) in parsed {
                if let intValue = value.asInt64 {
                    merged[key, default: 0] += intValue
                }
            }
        }
        return merged.map { Result.Counter(name: $0.key, value: $0.value) }
    }

    private func aggregateByCategory(counters: [Result.Counter]) -> [String: Int64] {
        var byCategory: [String: Int64] = [:]
        for counter in counters {
            let category = counter.name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? "Other"
            byCategory[category, default: 0] += counter.value
        }
        return byCategory
    }
}
