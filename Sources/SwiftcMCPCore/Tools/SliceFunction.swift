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
        /// Absolute path of the source file the symbol came from. With
        /// directory / package inputs, multiple symbols can share a name and
        /// only differ by file (e.g. internal helpers with the same name in
        /// peer files). Always populated.
        public let filePath: String
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
        // xcode inputs are deferred — we don't yet have a tested path for
        // dumping every Swift file Xcode wires into a target.
        switch input {
        case .file, .directory, .swiftPMPackage:
            break
        case .xcodeProject, .xcodeWorkspace:
            throw MCPError.invalidParams("slice_function does not yet support xcodeProject / xcodeWorkspace inputs. File / directory / package cases are supported.")
        }
        let includeImports = dict["include_imports"]?.asBool ?? true

        let resolved = try await resolver.resolveArgs(for: input)
        guard !resolved.inputFiles.isEmpty else {
            throw MCPError.internalError("Resolver returned no input files for the given input")
        }
        let target = resolved.target

        // Read every input file's source up-front. The slicer needs each file's
        // raw text to render a `SourceRangeMapper` slice, and the import-line
        // sweep also pulls from every source.
        var sourcesByPath: [String: String] = [:]
        for path in resolved.inputFiles {
            do {
                sourcesByPath[path] = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw MCPError.invalidParams("Could not read \(path): \(error.localizedDescription)")
            }
        }

        let start = Date()
        // Multi-file dump-ast: pass every input file in one swiftc invocation
        // so the AST is type-checked against the entire module. Single-file
        // dumps would miss cross-file type lookups (e.g. `App/main.swift`
        // referencing a type defined in `Core/Counter.swift`) and produce
        // wrong references.
        // Forward every option the resolver produced — searchPaths,
        // frameworkSearchPaths, and extraSwiftcArgs — so cross-target imports
        // (App → Core in MultiTargetPackage), Apple framework imports
        // (UIKit/Foundation needing -sdk + -F), and resolver-supplied flags
        // (-swift-version, etc.) all reach swiftc. Dropping any of them on
        // the floor surfaces as "no such module 'X'" or unresolved-type
        // errors during -dump-ast for any input that has an internal
        // dependency. The same channel api_diff's materializeModule uses.
        let astOutcome = try await invocation.run(
            modeArgs: ["-dump-ast"],
            inputFiles: resolved.inputFiles,
            outputFile: nil,
            options: .init(resolved: resolved)
        )
        // Channel fallback: single-file `swiftc -dump-ast` writes the AST to
        // stdout, but multi-file invocations route the entire AST to stderr
        // and leave stdout empty. We prefer whichever channel actually carries
        // the `(source_file …)` payload — stdout when non-empty, otherwise
        // stderr. This is a Swift-toolchain quirk confirmed against
        // 6.3.x; revisit if a future probe shows convergence.
        let astText: String
        if !astOutcome.process.standardOutput.isEmpty {
            astText = astOutcome.process.standardOutput
        } else {
            astText = astOutcome.process.standardError
        }

        let index = DeclIndex.build(astText: astText)
        let startEntry = try selectStartEntry(index: index, functionName: functionName)

        let graph = DependencyGraph(index: index, astText: astText)
        let graphOutput = graph.transitiveClosure(startingAt: startEntry)

        var pieces: [String] = []
        if includeImports {
            // Collect imports across every input file, then dedupe and sort
            // so the slice opens with a single canonical block. Without
            // deduping, a directory input with `import Foundation` in five
            // files would emit five copies.
            var seenImports: Set<String> = []
            var importLinesList: [String] = []
            for (_, source) in sourcesByPath.sorted(by: { $0.key < $1.key }) {
                for line in importLinesArray(from: source) where !seenImports.contains(line) {
                    seenImports.insert(line)
                    importLinesList.append(line)
                }
            }
            if !importLinesList.isEmpty {
                pieces.append(importLinesList.joined(separator: "\n"))
            }
        }
        // Group closure entries by source file. Each file gets its own
        // merge-and-render pass (line numbers are per-file, so a single global
        // merge would conflate ranges across files). Files are emitted in a
        // stable order — sorted by path — so callers get a deterministic slice.
        let entriesByFile = Dictionary(grouping: graphOutput.closure) { $0.filePath }
        for filePath in entriesByFile.keys.sorted() {
            let fileEntries = entriesByFile[filePath] ?? []
            guard let source = sourcesByPath[filePath] else { continue }
            let mapper = SourceRangeMapper(source: source)
            let mergedRanges = Self.mergeOverlappingRanges(fileEntries)
            for range in mergedRanges {
                if let text = mapper.substringForLines(startLine: range.lowerBound, endLine: range.upperBound) {
                    pieces.append(text)
                }
            }
        }
        let slicedCode = pieces.joined(separator: "\n\n") + "\n"

        let verification = try await verify(
            slicedCode: slicedCode,
            resolved: resolved
        )

        let included = graphOutput.closure.map { entry in
            IncludedSymbol(
                filePath: entry.filePath,
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

    /// Merge overlapping `[startLine, endLine]` intervals from the BFS closure into
    /// disjoint ranges, in source order. Strictly-overlapping ranges are unioned;
    /// adjacent-but-disjoint ones (e.g. `func a` ends on line 3, `func b` starts on
    /// line 5) stay separate so the rendered slice keeps a blank line between them
    /// when the original source had one.
    static func mergeOverlappingRanges(_ entries: [DeclIndex.Entry]) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = entries.map { $0.startLine...$0.endLine }
        ranges.sort { lhs, rhs in
            if lhs.lowerBound == rhs.lowerBound {
                return lhs.upperBound < rhs.upperBound
            }
            return lhs.lowerBound < rhs.lowerBound
        }
        var merged: [ClosedRange<Int>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                let unioned = last.lowerBound...max(last.upperBound, range.upperBound)
                merged[merged.count - 1] = unioned
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func importLinesArray(from source: String) -> [String] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("import ")
            }
    }

    private func verify(
        slicedCode: String,
        resolved: ResolvedBuildArgs
    ) async throws -> Verification {
        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let sourceURL = try scratch.write(name: "slice.swift", contents: slicedCode)

        // The verify pass must use the *same* search-path / framework / SDK
        // environment swiftc had during the original dump. Otherwise a slice
        // that legitimately keeps `import Core` (because the SwiftPM resolver
        // returned only App's inputFiles, leaving Core as an external
        // module) would fail typecheck with `no such module 'Core'` and
        // surface as a false self-containment failure. We reuse the same
        // `Options(resolved:)` channel `dump-ast` and api_diff use.
        async let typecheckOutcome = invocation.run(
            modeArgs: ["-typecheck"],
            inputFiles: [sourceURL.path],
            outputFile: nil,
            options: .init(resolved: resolved)
        )
        async let dumpAstOutcome = invocation.run(
            modeArgs: ["-dump-ast"],
            inputFiles: [sourceURL.path],
            outputFile: nil,
            options: .init(resolved: resolved)
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
