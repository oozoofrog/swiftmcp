import Foundation

/// `emit_sil`: emit Swift Intermediate Language for a Swift source file, write to a
/// temp file, and return the path.
public struct EmitSILTool: MCPTool {
    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let path: String
        public let bytes: Int
        public let stage: String
        public let optimization: String
        public let formatUnstable: Bool
        public let compilerExitCode: Int32
        public let compilerStderr: String?
    }

    private let invocation: SwiftcInvocation

    public init(toolchain: ToolchainResolver) {
        self.invocation = SwiftcInvocation(resolver: toolchain)
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "emit_sil",
            title: "Emit SIL",
            description: """
            Emit Swift Intermediate Language for a source file via swiftc. Stage selects \
            `raw` (silgen, before mandatory passes), `canonical` (default, after mandatory \
            passes), or `lowered` (post-IRGen-prep). Optimization controls `-Onone`/`-O`/`-Osize`/\
            `-Ounchecked`. SIL textual format is not version-stable across compiler releases.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "file": .object([
                        "type": .string("string"),
                        "description": .string("Path to a Swift source file.")
                    ]),
                    "stage": .object([
                        "type": .string("string"),
                        "description": .string("`raw`, `canonical`, or `lowered`. Default `canonical`."),
                        "default": .string("canonical")
                    ]),
                    "optimization": .object([
                        "type": .string("string"),
                        "description": .string("`none`, `speed`, `size`, or `unchecked`. Default `none`."),
                        "default": .string("none")
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
        let stage = dict["stage"]?.asString ?? "canonical"
        let optimizationKey = dict["optimization"]?.asString ?? "none"
        let target = dict["target"]?.asString

        let modeArgs: [String]
        let fileExtension: String
        switch stage {
        case "raw":
            modeArgs = ["-emit-silgen"]
            fileExtension = "silgen.sil"
        case "canonical":
            modeArgs = ["-emit-sil"]
            fileExtension = "sil"
        case "lowered":
            modeArgs = ["-emit-lowered-sil"]
            fileExtension = "lowered.sil"
        default:
            throw MCPError.invalidParams("`stage` must be one of: raw, canonical, lowered")
        }

        guard let optimization = SwiftcInvocation.Options.Optimization(rawValue: optimizationKey) else {
            throw MCPError.invalidParams("`optimization` must be one of: none, speed, size, unchecked")
        }

        let scratch = try PersistentScratch()
        let outputURL = scratch.directory.appending(path: fileExtension, directoryHint: .notDirectory)

        let start = Date()
        let outcome = try await invocation.run(
            modeArgs: modeArgs,
            inputFile: file,
            outputFile: outputURL,
            options: .init(target: target, optimization: optimization)
        )
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let result = Result(
            meta: .init(
                toolchain: .init(path: outcome.toolchain.swiftcPath, version: outcome.toolchain.version),
                target: target,
                durationMs: durationMs
            ),
            path: outputURL.path,
            bytes: fileSize(at: outputURL),
            stage: stage,
            optimization: optimization.rawValue,
            formatUnstable: true,
            compilerExitCode: outcome.process.exitCode,
            compilerStderr: outcome.process.standardError.isEmpty ? nil : outcome.process.standardError
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }
}
