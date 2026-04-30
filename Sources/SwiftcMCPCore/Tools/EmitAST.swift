import Foundation

/// `emit_ast`: dump the AST of Swift inputs via swiftc, write it to a temp file,
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
    private let resolver: BuildArgsResolver

    public init(toolchain: ToolchainResolver, resolver: BuildArgsResolver = DefaultBuildArgsResolver()) {
        self.invocation = SwiftcInvocation(resolver: toolchain)
        self.resolver = resolver
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "emit_ast",
            title: "Emit AST",
            description: """
            Dump the type-checked AST of a Swift source file or directory via `swiftc -dump-ast`. \
            Writes to a temp file and returns the path. Format may be `text` (S-expression), \
            `json` (parseable but not stable across compiler versions), or `json-zlib` \
            (compressed JSON). The AST format itself is not version-stable; \
            `formatUnstable: true` is always set as a reminder.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "input": BuildInput.jsonSchemaProperty,
                    "format": .object([
                        "type": .string("string"),
                        "description": .string("`text`, `json`, or `json-zlib`. Default `text`."),
                        "default": .string("text")
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
        let format = dict["format"]?.asString ?? "text"

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

        let resolved = try await resolver.resolveArgs(for: input)

        let scratch = try PersistentScratch()
        let outputURL = scratch.directory.appending(path: fileExtension, directoryHint: .notDirectory)

        // swiftc rejects `-o` with multi-file `-dump-ast` (and ignores `-wmo` here too:
        // "warning: ignoring '-wmo' because '-dump-ast' was also specified"). For
        // multi-file input we drop `-o`, let swiftc dump the AST to stderr, then write
        // it to the scratch file ourselves to keep the response shape unchanged.
        let multiFile = resolved.inputFiles.count > 1
        let invocationOutput: URL? = multiFile ? nil : outputURL

        let start = Date()
        let outcome = try await invocation.run(
            modeArgs: modeArgs,
            inputFiles: resolved.inputFiles,
            outputFile: invocationOutput,
            options: .init(resolved: resolved)
        )
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        var compilerStderr: String? = outcome.process.standardError.isEmpty ? nil : outcome.process.standardError
        if multiFile {
            // The dump itself lands on stderr; persist that, and stop reporting it as a
            // diagnostic stream. (Real diagnostics, if any, would be intermingled — we
            // accept that limitation as a Stage 3.A simplification.)
            try outcome.process.standardError.write(to: outputURL, atomically: true, encoding: .utf8)
            compilerStderr = nil
        }

        let bytes = fileSize(at: outputURL)

        let result = Result(
            meta: .init(
                toolchain: .init(path: outcome.toolchain.swiftcPath, version: outcome.toolchain.version),
                target: input.target,
                durationMs: durationMs
            ),
            path: outputURL.path,
            bytes: bytes,
            format: format,
            formatUnstable: true,
            compilerExitCode: outcome.process.exitCode,
            compilerStderr: compilerStderr
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
