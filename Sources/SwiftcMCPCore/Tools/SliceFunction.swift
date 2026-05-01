import Foundation

/// `slice_function`: extract a named function and its transitively referenced
/// declarations from a single Swift file, returning a self-contained source slice.
///
/// Pipeline:
/// 1. `swiftc -dump-ast <file>` → AST stdout.
/// 2. `DeclIndex.build` parses the top-level decls (functions, types, extensions,
///    typealiases, top-level vars).
/// 3. The named function is looked up. Multi-overload base names without an exact
///    `signature_key` are an `invalidParams` error so callers don't silently get
///    the first one.
/// 4. `DependencyGraph.transitiveClosure` walks references via `ReferenceCollector`
///    until no new in-file deps remain. Names that don't resolve to a top-level
///    decl land in `externalReferences`.
/// 5. The closure is rendered to source via `SourceRangeMapper.substringForLines`,
///    optionally prefixed with the file's `import` lines.
/// 6. The slice is run through `swiftc -typecheck` for self-containment verification.
///    Diagnostics are classified by `MissingSymbolClassifier` so the caller can see
///    which symbols (if any) the slice failed to resolve on its own.
public struct SliceFunctionTool: MCPTool {
    public struct IncludedSymbol: Sendable, Codable, Equatable {
        public let name: String
        public let signatureKey: String
        public let kind: DeclIndex.Entry.Kind
        public let startLine: Int
        public let endLine: Int
    }

    public struct Verification: Sendable, Codable, Equatable {
        public let compilerExitCode: Int32
        public let unresolvedReferences: [MissingSymbol]
        public let diagnostics: [CompilerDiagnostic]
    }

    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let slicedCode: String
        public let includedSymbols: [IncludedSymbol]
        public let externalReferences: [String]
        public let verification: Verification
        public let warnings: [String]
    }

    private let toolchain: ToolchainResolver
    private let invocation: SwiftcInvocation
    private let resolver: BuildArgsResolver
    private let parser = DiagnosticParser()

    public init(toolchain: ToolchainResolver, resolver: BuildArgsResolver = DefaultBuildArgsResolver()) {
        self.toolchain = toolchain
        self.invocation = SwiftcInvocation(resolver: toolchain)
        self.resolver = resolver
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "slice_function",
            title: "Slice Function",
            description: """
            Extract a named function plus its transitively referenced declarations \
            from a single Swift file. Returns a self-contained Swift source string \
            (`slicedCode`) plus the list of included symbols and any names that \
            referenced external definitions (`externalReferences`). The slice is \
            type-checked once via swiftc and the result is reported in `verification` \
            so callers can see whether more stubs are needed.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "input": BuildInput.jsonSchemaProperty,
                    "function_name": .object([
                        "type": .string("string"),
                        "description": .string("Function to slice. Either a base name (e.g. `describe`) or a swiftc-style key (e.g. `describe(_:)`). Base names that match multiple overloads return an invalidParams error listing the candidates.")
                    ]),
                    "include_imports": .object([
                        "type": .string("boolean"),
                        "description": .string("Prepend the original file's `import` lines to the slice. Default true."),
                        "default": .bool(true)
                    ])
                ]),
                "required": .array([.string("input"), .string("function_name")])
            ])
        )
    }

    public func call(arguments: JSONValue?) async throws -> CallToolResult {
        guard case .object(let dict) = arguments else {
            throw MCPError.invalidParams("arguments must be an object")
        }
        guard let functionName = dict["function_name"]?.asString, !functionName.isEmpty else {
            throw MCPError.invalidParams("`function_name` is required and must be a non-empty string")
        }
        let input = try BuildInput.decode(dict["input"])
        guard case .file(_, let target) = input else {
            throw MCPError.invalidParams("slice_function currently only supports `input.file`. Directory / package / project / workspace cases are deferred to a follow-up milestone.")
        }
        let includeImports = dict["include_imports"]?.asBool ?? true

        let resolved = try await resolver.resolveArgs(for: input)
        guard let absolutePath = resolved.inputFiles.first else {
            throw MCPError.internalError("LocalFilesResolver returned no input files for `.file` case")
        }

        let source: String
        do {
            source = try String(contentsOfFile: absolutePath, encoding: .utf8)
        } catch {
            throw MCPError.invalidParams("Could not read \(absolutePath): \(error.localizedDescription)")
        }

        let start = Date()
        let astOutcome = try await invocation.run(
            modeArgs: ["-dump-ast"],
            inputFiles: [absolutePath],
            outputFile: nil,
            options: .init(target: target)
        )
        let astText = astOutcome.process.standardOutput

        let index = DeclIndex.build(astText: astText)
        let startEntry = try selectStartEntry(index: index, functionName: functionName)

        let graph = DependencyGraph(index: index, astText: astText)
        let graphOutput = graph.transitiveClosure(startingAt: startEntry)

        let mapper = SourceRangeMapper(source: source)
        var pieces: [String] = []
        if includeImports {
            let importBlock = importLines(from: source)
            if !importBlock.isEmpty {
                pieces.append(importBlock)
            }
        }
        for entry in graphOutput.closure {
            if let text = mapper.substringForLines(startLine: entry.startLine, endLine: entry.endLine) {
                pieces.append(text)
            }
        }
        let slicedCode = pieces.joined(separator: "\n\n") + "\n"

        let verification = try await verify(
            slicedCode: slicedCode,
            target: target
        )

        let included = graphOutput.closure.map { entry in
            IncludedSymbol(
                name: entry.name,
                signatureKey: entry.signatureKey,
                kind: entry.kind,
                startLine: entry.startLine,
                endLine: entry.endLine
            )
        }

        let warnings: [String] = [
            "AST text format is not version-stable; slicing relies on Swift 6.x node shapes (parameter / pattern_named / func_decl / struct/class/enum/protocol/typealias_decl / extension_decl / declref_expr / type_unqualified_ident).",
            "Conditional compilation (`#if`) blocks are observed only on the active branch; inactive branches are not analyzed.",
            "Property wrappers, result builders, and macro expansions are best-effort: their generated decls are not specifically tracked."
        ]

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        let result = Result(
            meta: .init(
                toolchain: .init(path: astOutcome.toolchain.swiftcPath, version: astOutcome.toolchain.version),
                target: target,
                durationMs: durationMs
            ),
            slicedCode: slicedCode,
            includedSymbols: included,
            externalReferences: graphOutput.externalReferences,
            verification: verification,
            warnings: warnings
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }

    // MARK: - Helpers

    private func selectStartEntry(index: DeclIndex, functionName: String) throws -> DeclIndex.Entry {
        // Allow exact `signatureKey` match (handles overloads + non-function decls).
        if let exact = index.find(signatureKey: functionName) {
            return exact
        }
        let candidates = index.find(name: functionName).filter { $0.kind == .function }
        switch candidates.count {
        case 0:
            throw MCPError.invalidParams("Function '\(functionName)' not found at top level of the file")
        case 1:
            return candidates[0]
        default:
            let keys = candidates.map(\.signatureKey).joined(separator: ", ")
            throw MCPError.invalidParams("Function '\(functionName)' is overloaded (\(keys)). Provide the exact `signatureKey` (e.g. `\(candidates[0].signatureKey)`) instead of the base name.")
        }
    }

    private func importLines(from source: String) -> String {
        let imports = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("import ")
            }
        return imports.joined(separator: "\n")
    }

    private func verify(
        slicedCode: String,
        target: String?
    ) async throws -> Verification {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let sourceURL = try scratch.write(name: "slice.swift", contents: slicedCode)

        async let typecheckOutcome = invocation.run(
            modeArgs: ["-typecheck"],
            inputFiles: [sourceURL.path],
            outputFile: nil,
            options: .init(target: target)
        )
        async let dumpAstOutcome = invocation.run(
            modeArgs: ["-dump-ast"],
            inputFiles: [sourceURL.path],
            outputFile: nil,
            options: .init(target: target)
        )
        let (typecheck, dumpAst) = try await (typecheckOutcome, dumpAstOutcome)

        let diagnostics = parser.parse(typecheck.process.standardError)
        let declared = ASTIdentifierExtractor.extractDeclaredIdentifiers(astText: dumpAst.process.standardOutput)
        let classification = MissingSymbolClassifier.classify(
            diagnostics: diagnostics,
            sourceCode: slicedCode,
            declaredIdentifiers: declared
        )
        return Verification(
            compilerExitCode: typecheck.process.exitCode,
            unresolvedReferences: classification.symbols,
            diagnostics: classification.unclassified
        )
    }
}
