import Foundation

/// `emit_ir`: emit LLVM IR (or pre-LLVM-opt IR, or bitcode) for a Swift source file.
public struct EmitIRTool: MCPTool {
    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let path: String
        public let bytes: Int
        public let stage: String
        public let optimization: String
        public let isBinary: Bool
        public let compilerExitCode: Int32
        public let compilerStderr: String?
    }

    private let invocation: SwiftcInvocation

    public init(toolchain: ToolchainResolver) {
        self.invocation = SwiftcInvocation(resolver: toolchain)
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "emit_ir",
            title: "Emit LLVM IR",
            description: """
            Emit LLVM intermediate representation for a Swift source file. Stage selects \
            `irgen` (textual IR before LLVM optimizations), `ir` (textual IR after LLVM \
            optimizations, default), or `bc` (binary LLVM bitcode). Optimization controls \
            `-Onone`/`-O`/`-Osize`/`-Ounchecked`.
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
                        "description": .string("`irgen`, `ir`, or `bc`. Default `ir`."),
                        "default": .string("ir")
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
        let stage = dict["stage"]?.asString ?? "ir"
        let optimizationKey = dict["optimization"]?.asString ?? "none"
        let target = dict["target"]?.asString

        let modeArgs: [String]
        let fileExtension: String
        let isBinary: Bool
        switch stage {
        case "irgen":
            modeArgs = ["-emit-irgen"]
            fileExtension = "irgen.ll"
            isBinary = false
        case "ir":
            modeArgs = ["-emit-ir"]
            fileExtension = "ll"
            isBinary = false
        case "bc":
            modeArgs = ["-emit-bc"]
            fileExtension = "bc"
            isBinary = true
        default:
            throw MCPError.invalidParams("`stage` must be one of: irgen, ir, bc")
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
            isBinary: isBinary,
            compilerExitCode: outcome.process.exitCode,
            compilerStderr: outcome.process.standardError.isEmpty ? nil : outcome.process.standardError
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }
}
