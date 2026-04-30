import Foundation

/// `emit_ast`: dump the AST of a Swift source file via swiftc, write it to a temp file,
/// and return the file path. The artifact body is not embedded in the response per the
/// response-size policy.
public struct EmitASTTool: MCPTool {
    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let path: String
        public let bytes: Int
        public let format: String
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
            name: "emit_ast",
            title: "Emit AST",
            description: """
            Dump the type-checked AST of a Swift source file via `swiftc -dump-ast`. \
            Writes to a temp file and returns the path. Format may be `text` (S-expression), \
            `json` (parseable but not stable across compiler versions), or `json-zlib` \
            (compressed JSON). The AST format itself is not version-stable; \
            `formatUnstable: true` is always set as a reminder.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "file": .object([
                        "type": .string("string"),
                        "description": .string("Path to a Swift source file.")
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "description": .string("`text`, `json`, or `json-zlib`. Default `text`."),
                        "default": .string("text")
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
        let format = dict["format"]?.asString ?? "text"
        let target = dict["target"]?.asString

        let modeArgs: [String]
        let fileExtension: String
        switch format {
        case "text":
            modeArgs = ["-dump-ast"]
            fileExtension = "ast.txt"
        case "json":
            modeArgs = ["-dump-ast", "-dump-ast-format", "json"]
            fileExtension = "ast.json"
        case "json-zlib":
            modeArgs = ["-dump-ast", "-dump-ast-format", "json-zlib"]
            fileExtension = "ast.json.zlib"
        default:
            throw MCPError.invalidParams("`format` must be one of: text, json, json-zlib")
        }

        let scratch = try PersistentScratch()
        let outputURL = scratch.directory.appending(path: fileExtension, directoryHint: .notDirectory)

        let start = Date()
        let outcome = try await invocation.run(
            modeArgs: modeArgs,
            inputFile: file,
            outputFile: outputURL,
            options: .init(target: target)
        )
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let bytes = fileSize(at: outputURL)

        let result = Result(
            meta: .init(
                toolchain: .init(path: outcome.toolchain.swiftcPath, version: outcome.toolchain.version),
                target: target,
                durationMs: durationMs
            ),
            path: outputURL.path,
            bytes: bytes,
            format: format,
            formatUnstable: true,
            compilerExitCode: outcome.process.exitCode,
            compilerStderr: outcome.process.standardError.isEmpty ? nil : outcome.process.standardError
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }
}

func fileSize(at url: URL) -> Int {
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attrs[.size] as? Int {
        return size
    }
    return 0
}
