import Foundation

/// `emit_ir`: emit LLVM IR (or pre-LLVM-opt IR, or bitcode) for Swift inputs.
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
    private let resolver: BuildArgsResolver

    public init(toolchain: ToolchainResolver, resolver: BuildArgsResolver = DefaultBuildArgsResolver()) {
        self.invocation = SwiftcInvocation(resolver: toolchain)
        self.resolver = resolver
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "emit_ir",
            title: "Emit LLVM IR",
            description: """
            Emit LLVM intermediate representation for a Swift source file or directory. Stage \
            selects `irgen` (textual IR before LLVM optimizations), `ir` (textual IR after LLVM \
            optimizations, default), or `bc` (binary LLVM bitcode). Optimization controls \
            `-Onone`/`-O`/`-Osize`/`-Ounchecked`.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "input": BuildInput.jsonSchemaProperty,
                    "stage": .object([
                        "type": .string("string"),
                        "description": .string("`irgen`, `ir`, or `bc`. Default `ir`."),
                        "default": .string("ir")
                    ]),
                    "optimization": .object([
                        "type": .string("string"),
                        "description": .string("`none`, `speed`, `size`, or `unchecked`. Default `none`."),
                        "default": .string("none")
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
        let stage = dict["stage"]?.asString ?? "ir"
        let optimizationKey = dict["optimization"]?.asString ?? "none"

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

        let resolved = try await resolver.resolveArgs(for: input)

        let scratch = try PersistentScratch()
        let outputURL = scratch.directory.appending(path: fileExtension, directoryHint: .notDirectory)

        let start = Date()
        let outcome = try await invocation.run(
            modeArgs: modeArgs,
            inputFiles: resolved.inputFiles,
            outputFile: outputURL,
            options: .init(resolved: resolved, optimization: optimization)
        )
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let result = Result(
            meta: .init(
                toolchain: .init(path: outcome.toolchain.swiftcPath, version: outcome.toolchain.version),
                target: input.target,
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
