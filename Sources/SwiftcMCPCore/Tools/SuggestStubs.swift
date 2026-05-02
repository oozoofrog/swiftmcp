import Foundation

/// `suggest_stubs`: turn a list of missing symbols (or an inline snippet) into minimal
/// Swift stub declarations. Output is meant as a *starting point* the LLM should
/// refine — argument types are `Any`, return types are `Any`, function bodies are
/// `fatalError()`. The intent is to remove the "blank page" problem from the retry
/// loop, not to generate runnable code.
///
/// If `missingSymbols` is omitted, the tool runs the same -typecheck pass that
/// `report_missing_symbols` does and infers them itself. Skipping that round-trip
/// when the caller already has a list keeps the tool usable in an LLM-driven loop.
public struct SuggestStubsTool: MCPTool {
    public struct StubSuggestion: Sendable, Codable, Equatable {
        public let name: String
        public let kind: MissingSymbol.Kind
        public let swift: String
        public let rationale: String
    }

    public struct SkippedSymbol: Sendable, Codable, Equatable {
        public let name: String
        public let kind: MissingSymbol.Kind
        public let reason: String
    }

    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let stubsSwift: String
        public let stubs: [StubSuggestion]
        public let skipped: [SkippedSymbol]
        public let resolvedFromCompiler: Bool
    }

    private let invocation: SwiftcInvocation
    private let toolchain: ToolchainResolver
    private let parser = DiagnosticParser()

    public init(toolchain: ToolchainResolver) {
        self.toolchain = toolchain
        self.invocation = SwiftcInvocation(resolver: toolchain)
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "suggest_stubs",
            title: "Suggest Stubs",
            description: """
            Generate minimal Swift stub declarations for missing symbols in a code \
            snippet. If `missing_symbols` is provided, the tool uses that list \
            directly; otherwise it runs `swiftc -typecheck` and classifies the \
            resulting diagnostics itself. Stubs use `Any` for unknown types and \
            `fatalError()` bodies — they are starting points for the LLM to refine, \
            not finished code. Modules cannot be stubbed and land in `skipped`.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("The Swift source the stubs should accompany. Used both for context (call-site arity) and, when `missing_symbols` is omitted, for diagnostic discovery.")
                    ]),
                    "missing_symbols": .object([
                        "type": .string("array"),
                        "description": .string("Optional pre-classified list (the shape `report_missing_symbols` returns). When omitted the tool re-derives it from a typecheck pass.")
                    ]),
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Optional target triple. Used only when `missing_symbols` is omitted.")
                    ])
                ]),
                "required": .array([.string("code")])
            ])
        )
    }

    public func call(arguments: JSONValue?) async throws -> CallToolResult {
        guard case .object(let dict) = arguments,
              let code = dict["code"]?.asString, !code.isEmpty
        else {
            throw MCPError.invalidParams("`code` argument is required and must be a non-empty string")
        }
        let target = dict["target"]?.asString

        let start = Date()

        // Resolve missing symbols: prefer caller-supplied, fall back to a fresh
        // typecheck pass.
        let missingSymbols: [MissingSymbol]
        let resolvedFromCompiler: Bool
        let toolchainMeta: ToolOutputMeta.Toolchain

        if let inline = dict["missing_symbols"], case .array = inline {
            // Caller-supplied list. We do NOT silently drop falsePositive entries —
            // they must surface in `skipped` so the caller learns we ignored them
            // (otherwise the LLM might think `suggest_stubs` covered every symbol it
            // passed in). Same end-result as the self-derived path below.
            missingSymbols = try decodeMissingSymbols(inline)
            resolvedFromCompiler = false
            let resolved = try await toolchain.resolve()
            toolchainMeta = .init(path: resolved.swiftcPath, version: resolved.version)
        } else {
            let scratch = try CallScratch()
            defer { scratch.dispose() }
            let sourceURL = try scratch.write(name: "main.swift", contents: code)

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
            let declared = ASTIdentifierExtractor.extractDeclaredIdentifiers(
                astText: dumpAst.process.standardOutput
            )
            let classification = MissingSymbolClassifier.classify(
                diagnostics: diagnostics,
                sourceCode: code,
                declaredIdentifiers: declared
            )
            // Self-derived path also goes through StubBuilder so falsePositive
            // entries land in `skipped` with a uniform reason (instead of being
            // silently filtered out before the builder ever sees them).
            missingSymbols = classification.symbols
            resolvedFromCompiler = true
            toolchainMeta = .init(
                path: typecheck.toolchain.swiftcPath,
                version: typecheck.toolchain.version
            )
        }

        let (stubs, skipped) = StubBuilder.buildStubs(for: missingSymbols, sourceCode: code)
        let combined = stubs.map(\.swift).joined(separator: "\n")
        let stubsSwift: String
        if combined.isEmpty {
            stubsSwift = ""
        } else {
            stubsSwift = "// Auto-generated stubs by suggest_stubs.\n" + combined + "\n"
        }
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let result = Result(
            meta: .init(
                toolchain: toolchainMeta,
                target: target,
                durationMs: durationMs
            ),
            stubsSwift: stubsSwift,
            stubs: stubs,
            skipped: skipped,
            resolvedFromCompiler: resolvedFromCompiler
        )
        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }

    private func decodeMissingSymbols(_ value: JSONValue) throws -> [MissingSymbol] {
        let data = try JSONEncoder().encode(value)
        do {
            return try JSONDecoder().decode([MissingSymbol].self, from: data)
        } catch {
            throw MCPError.invalidParams("`missing_symbols` is not in the expected shape: \(error)")
        }
    }
}

/// Pure stub-building. Lives next to `SuggestStubsTool` so its rules are visible.
enum StubBuilder {
    static func buildStubs(
        for symbols: [MissingSymbol],
        sourceCode: String
    ) -> (stubs: [SuggestStubsTool.StubSuggestion], skipped: [SuggestStubsTool.SkippedSymbol]) {
        var stubs: [SuggestStubsTool.StubSuggestion] = []
        var skipped: [SuggestStubsTool.SkippedSymbol] = []
        for symbol in symbols {
            // falsePositive shadows kind: classifier already saw the name in the AST's
            // declared pool, so generating a stub would shadow a real declaration.
            // Surface the symbol in `skipped` so the caller knows we saw it.
            if symbol.falsePositive {
                skipped.append(.init(
                    name: symbol.name,
                    kind: symbol.kind,
                    reason: "name is already declared elsewhere in the snippet (likely a typo); refusing to stub"
                ))
                continue
            }
            switch symbol.kind {
            case .module:
                skipped.append(.init(
                    name: symbol.name,
                    kind: .module,
                    reason: "module imports cannot be stubbed; provide the actual dependency"
                ))
            case .type:
                stubs.append(stubForType(symbol))
            case .value:
                stubs.append(stubForValue(symbol, sourceCode: sourceCode))
            }
        }
        return (stubs, skipped)
    }

    private static func stubForType(_ symbol: MissingSymbol) -> SuggestStubsTool.StubSuggestion {
        // Generic empty struct; the `init()` makes `Type()` and `.init()` both work.
        let swift = "struct \(symbol.name) { public init() {} }"
        return .init(
            name: symbol.name,
            kind: .type,
            swift: swift,
            rationale: "type referenced as \(symbol.usagePattern.rawValue); empty struct with public init()"
        )
    }

    private static func stubForValue(
        _ symbol: MissingSymbol,
        sourceCode: String
    ) -> SuggestStubsTool.StubSuggestion {
        switch symbol.usagePattern {
        case .call:
            let arity = inferCallArity(name: symbol.name, sourceCode: sourceCode)
            let params = (0..<arity).map { "_ a\($0): Any" }.joined(separator: ", ")
            let swift = "func \(symbol.name)(\(params)) -> Any { fatalError(\"\(symbol.name) is a stub\") }"
            return .init(
                name: symbol.name,
                kind: .value,
                swift: swift,
                rationale: arity == 0
                    ? "call site has no arguments; stub takes none"
                    : "call site appears to have \(arity) argument(s); typed as Any"
            )
        case .memberAccess:
            // We don't try to infer the parent type here; the LLM will likely have
            // a separate `kind: .type` entry for the parent. Fall back to a free var.
            let swift = "var \(symbol.name): Any = fatalError(\"\(symbol.name) is a stub\")"
            return .init(
                name: symbol.name,
                kind: .value,
                swift: swift,
                rationale: "value used in member-access form; stub as a free variable for now"
            )
        case .typeAnnotation, .importStatement, .unknown:
            let swift = "let \(symbol.name): Any = fatalError(\"\(symbol.name) is a stub\")"
            return .init(
                name: symbol.name,
                kind: .value,
                swift: swift,
                rationale: "bare reference; stub as a constant of Any"
            )
        }
    }

    /// Count the top-level commas inside the first `<name>(…)` call site we can find.
    /// 0 args when the parens are immediately closed; otherwise commas + 1.
    static func inferCallArity(name: String, sourceCode: String) -> Int {
        guard let openRange = sourceCode.range(of: "\(name)(") else { return 0 }
        var depth = 1
        var commas = 0
        var sawNonWhitespace = false
        var index = openRange.upperBound
        while index < sourceCode.endIndex {
            let ch = sourceCode[index]
            if depth == 1 && ch == "," {
                commas += 1
            } else if ch == "(" || ch == "[" || ch == "{" {
                depth += 1
            } else if ch == ")" || ch == "]" || ch == "}" {
                depth -= 1
                if depth == 0 {
                    break
                }
            } else if !ch.isWhitespace {
                sawNonWhitespace = true
            }
            index = sourceCode.index(after: index)
        }
        if !sawNonWhitespace { return 0 }
        return commas + 1
    }
}

