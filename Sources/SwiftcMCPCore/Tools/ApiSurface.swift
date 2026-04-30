import Foundation

/// `api_surface`: emit DocC-format symbol graph + API descriptor for a Swift source
/// file and return paths + counts. The full JSON artifacts live on disk in a
/// `PersistentScratch` directory; this tool reports their paths plus aggregate
/// statistics (per-kind counts, totals) so clients can decide whether to open the
/// artifact files or work from summaries alone.
public struct ApiSurfaceTool: MCPTool {
    public struct SymbolGraphFile: Sendable, Codable, Equatable {
        public let name: String
        public let path: String
        public let module: String?
        public let symbols: Int
        public let relationships: Int
    }

    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let moduleName: String
        public let minAccessLevel: String
        public let symbolGraphDir: String
        public let symbolGraphFiles: [SymbolGraphFile]
        public let apiDescriptorPath: String
        public let apiDescriptorBytes: Int
        public let totalSymbols: Int
        public let totalRelationships: Int
        public let symbolKinds: [String: Int]
        public let compilerExitCode: Int32
        public let compilerStderr: String?
    }

    private let toolchain: ToolchainResolver

    public init(toolchain: ToolchainResolver) {
        self.toolchain = toolchain
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "api_surface",
            title: "API Surface",
            description: """
            Emit a DocC-format symbol graph and an API descriptor for a Swift source file. \
            The tool runs `swiftc -emit-module -emit-symbol-graph -emit-api-descriptor-path` \
            with all build artifacts (the `.swiftmodule` and friends) placed in a temp \
            directory so the caller's working directory stays clean. Returns the artifact \
            paths plus aggregate symbol/relationship/kind counts. The full JSON is on disk \
            and not embedded in the response per the response-size policy.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "file": .object([
                        "type": .string("string"),
                        "description": .string("Path to a Swift source file.")
                    ]),
                    "module_name": .object([
                        "type": .string("string"),
                        "description": .string("Module name for the emitted symbol graph. Defaults to the file's basename without extension.")
                    ]),
                    "min_access_level": .object([
                        "type": .string("string"),
                        "description": .string("`-symbol-graph-minimum-access-level` value: `open`, `public`, `package`, `internal`, `fileprivate`, or `private`. Default `public`."),
                        "default": .string("public")
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
        let target = dict["target"]?.asString
        let minAccessLevel = dict["min_access_level"]?.asString ?? "public"
        guard ["open", "public", "package", "internal", "fileprivate", "private"].contains(minAccessLevel) else {
            throw MCPError.invalidParams("`min_access_level` must be one of: open, public, package, internal, fileprivate, private")
        }
        let moduleName: String
        if let provided = dict["module_name"]?.asString, !provided.isEmpty {
            moduleName = provided
        } else {
            let url = URL(fileURLWithPath: file)
            let basename = url.deletingPathExtension().lastPathComponent
            moduleName = basename.isEmpty ? "Module" : basename
        }

        let resolved = try await toolchain.resolve()
        let scratch = try PersistentScratch()
        let dir = scratch.directory
        let modulePath = dir.appending(path: "\(moduleName).swiftmodule", directoryHint: .notDirectory)
        let apiPath = dir.appending(path: "api.json", directoryHint: .notDirectory)

        var arguments: [String] = [
            "-emit-module",
            "-emit-module-path", modulePath.path,
            "-emit-symbol-graph",
            "-emit-symbol-graph-dir", dir.path,
            "-emit-api-descriptor-path", apiPath.path,
            "-symbol-graph-minimum-access-level", minAccessLevel,
            "-module-name", moduleName
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

        let symbolGraphFiles = readSymbolGraphFiles(in: dir)
        let totalSymbols = symbolGraphFiles.reduce(0) { $0 + $1.symbols }
        let totalRelationships = symbolGraphFiles.reduce(0) { $0 + $1.relationships }
        let symbolKinds = aggregateSymbolKinds(graphFiles: symbolGraphFiles, dir: dir)

        let result = Result(
            meta: .init(
                toolchain: .init(path: resolved.swiftcPath, version: resolved.version),
                target: target,
                durationMs: durationMs
            ),
            moduleName: moduleName,
            minAccessLevel: minAccessLevel,
            symbolGraphDir: dir.path,
            symbolGraphFiles: symbolGraphFiles,
            apiDescriptorPath: apiPath.path,
            apiDescriptorBytes: fileSize(at: apiPath),
            totalSymbols: totalSymbols,
            totalRelationships: totalRelationships,
            symbolKinds: symbolKinds,
            compilerExitCode: processResult.exitCode,
            compilerStderr: processResult.standardError.isEmpty ? nil : processResult.standardError
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }

    private func readSymbolGraphFiles(in dir: URL) -> [SymbolGraphFile] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(".symbols.json") }
        } catch {
            return []
        }
        return urls.compactMap { url -> SymbolGraphFile? in
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? JSONDecoder().decode(SymbolGraphHeader.self, from: data)
            else { return nil }
            return SymbolGraphFile(
                name: url.lastPathComponent,
                path: url.path,
                module: parsed.module?.name,
                symbols: parsed.symbols?.count ?? 0,
                relationships: parsed.relationships?.count ?? 0
            )
        }.sorted { $0.name < $1.name }
    }

    private func aggregateSymbolKinds(graphFiles: [SymbolGraphFile], dir: URL) -> [String: Int] {
        var kinds: [String: Int] = [:]
        for graph in graphFiles {
            let url = URL(fileURLWithPath: graph.path)
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? JSONDecoder().decode(SymbolGraphKindsOnly.self, from: data)
            else { continue }
            for symbol in parsed.symbols ?? [] {
                let id = symbol.kind?.identifier ?? "unknown"
                kinds[id, default: 0] += 1
            }
        }
        return kinds
    }
}

// MARK: - Lightweight Codable views over the symbol graph JSON

private struct SymbolGraphHeader: Decodable {
    struct Module: Decodable { let name: String? }
    struct AnyArray: Decodable {
        let count: Int
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var n = 0
            while !container.isAtEnd {
                _ = try container.decode(JSONValue.self)
                n += 1
            }
            self.count = n
        }
    }
    let module: Module?
    let symbols: AnyArray?
    let relationships: AnyArray?
}

private struct SymbolGraphKindsOnly: Decodable {
    struct Symbol: Decodable {
        struct Kind: Decodable { let identifier: String? }
        let kind: Kind?
    }
    let symbols: [Symbol]?
}
