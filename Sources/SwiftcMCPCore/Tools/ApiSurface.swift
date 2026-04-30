import Foundation

/// `api_surface`: emit DocC-format symbol graph + API descriptor for Swift inputs and
/// return paths + counts. The full JSON artifacts live on disk in a
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

    private let invocation: SwiftcInvocation
    private let resolver: BuildArgsResolver

    public init(toolchain: ToolchainResolver, resolver: BuildArgsResolver = DefaultBuildArgsResolver()) {
        self.invocation = SwiftcInvocation(resolver: toolchain)
        self.resolver = resolver
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "api_surface",
            title: "API Surface",
            description: """
            Emit a DocC-format symbol graph and an API descriptor for Swift inputs. \
            The tool runs `swiftc -emit-module -emit-symbol-graph -emit-api-descriptor-path` \
            with all build artifacts (the `.swiftmodule` and friends) placed in a temp \
            directory so the caller's working directory stays clean. Returns the artifact \
            paths plus aggregate symbol/relationship/kind counts. The full JSON is on disk \
            and not embedded in the response per the response-size policy.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "input": BuildInput.jsonSchemaProperty,
                    "module_name": .object([
                        "type": .string("string"),
                        "description": .string("Module name for the emitted symbol graph. Defaults to the input's basename without extension. (Also accepted via `input.module_name` for the directory case.)")
                    ]),
                    "min_access_level": .object([
                        "type": .string("string"),
                        "description": .string("`-symbol-graph-minimum-access-level` value: `open`, `public`, `package`, `internal`, `fileprivate`, or `private`. Default `public`."),
                        "default": .string("public")
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
        let minAccessLevel = dict["min_access_level"]?.asString ?? "public"
        guard ["open", "public", "package", "internal", "fileprivate", "private"].contains(minAccessLevel) else {
            throw MCPError.invalidParams("`min_access_level` must be one of: open, public, package, internal, fileprivate, private")
        }

        let resolved = try await resolver.resolveArgs(for: input)
        let topLevelOverride = dict["module_name"]?.asString.flatMap { $0.isEmpty ? nil : $0 }
        let moduleName: String
        if let topLevelOverride {
            moduleName = topLevelOverride
        } else if let resolvedName = resolved.moduleName, !resolvedName.isEmpty {
            moduleName = resolvedName
        } else if let firstFile = resolved.inputFiles.first {
            let basename = URL(fileURLWithPath: firstFile).deletingPathExtension().lastPathComponent
            moduleName = basename.isEmpty ? "Module" : basename
        } else {
            moduleName = "Module"
        }

        let scratch = try PersistentScratch()
        let dir = scratch.directory
        let modulePath = dir.appending(path: "\(moduleName).swiftmodule", directoryHint: .notDirectory)
        let apiPath = dir.appending(path: "api.json", directoryHint: .notDirectory)

        let extraArgs: [String] = [
            "-emit-module",
            "-emit-module-path", modulePath.path,
            "-emit-symbol-graph",
            "-emit-symbol-graph-dir", dir.path,
            "-emit-api-descriptor-path", apiPath.path,
            "-symbol-graph-minimum-access-level", minAccessLevel
        ]

        // Invocation auto-injects -module-name when options.moduleName is set; pass it
        // via Options so we don't double up.
        var options = SwiftcInvocation.Options(resolved: resolved)
        options = SwiftcInvocation.Options(
            target: options.target,
            optimization: options.optimization,
            moduleName: moduleName,
            searchPaths: options.searchPaths,
            frameworkSearchPaths: options.frameworkSearchPaths,
            extraSwiftcArgs: options.extraSwiftcArgs + extraArgs
        )

        let start = Date()
        let outcome = try await invocation.run(
            modeArgs: [],
            inputFiles: resolved.inputFiles,
            outputFile: nil,
            options: options
        )
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let symbolGraphFiles = readSymbolGraphFiles(in: dir)
        let totalSymbols = symbolGraphFiles.reduce(0) { $0 + $1.symbols }
        let totalRelationships = symbolGraphFiles.reduce(0) { $0 + $1.relationships }
        let symbolKinds = aggregateSymbolKinds(graphFiles: symbolGraphFiles, dir: dir)

        let result = Result(
            meta: .init(
                toolchain: .init(path: outcome.toolchain.swiftcPath, version: outcome.toolchain.version),
                target: input.target,
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
            compilerExitCode: outcome.process.exitCode,
            compilerStderr: outcome.process.standardError.isEmpty ? nil : outcome.process.standardError
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
