import Foundation

/// `report_missing_symbols`: type-check a Swift snippet, classify any missing-symbol
/// diagnostics into structured form, and cross-check the resulting names against the
/// AST's declared identifier pool to flag false positives (typically typos against
/// in-scope names).
///
/// First step of the Stage-4 retry loop the LLM runs: snippet in → structured list of
/// what's missing out. The companion `suggest_stubs` tool consumes this list to draft
/// minimal stub bodies the LLM can flesh out before invoking `build_isolated_snippet`.
public struct ReportMissingSymbolsTool: MCPTool {
    public struct Result: Sendable, Codable, Equatable {
        public let meta: ToolOutputMeta
        public let compilerExitCode: Int32
        public let missingSymbols: [MissingSymbol]
        public let rawDiagnostics: [CompilerDiagnostic]
        public let declaredIdentifiers: [String]
    }

    private let invocation: SwiftcInvocation
    private let parser = DiagnosticParser()

    public init(toolchain: ToolchainResolver) {
        self.invocation = SwiftcInvocation(resolver: toolchain)
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "report_missing_symbols",
            title: "Report Missing Symbols",
            description: """
            Type-check a Swift source string and return undeclared identifier / missing \
            type / missing module references in structured form. The result also \
            includes the AST's declared identifier pool so callers can spot typo \
            collisions (`falsePositive: true`) before generating stubs. swiftc \
            diagnostics that aren't 'cannot find … in scope'-style live in \
            `rawDiagnostics` for visibility.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("Self-contained Swift source. Top-level statements are fine.")
                    ]),
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Optional target triple. Default: host.")
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

        let scratch = try CallScratch()
        defer { scratch.dispose() }
        let sourceURL = try scratch.write(name: "main.swift", contents: code)

        let start = Date()

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
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let diagnostics = parser.parse(typecheck.process.standardError)
        // `-dump-ast` writes the S-expression AST to stdout; diagnostics (and any
        // header chatter) go to stderr. The extractor matches against
        // `(parameter "X")` / `(func_decl … "X(…)" …)` etc.
        let declaredIdentifiers = ASTIdentifierExtractor.extractDeclaredIdentifiers(
            astText: dumpAst.process.standardOutput
        )
        let classification = MissingSymbolClassifier.classify(
            diagnostics: diagnostics,
            sourceCode: code,
            declaredIdentifiers: declaredIdentifiers
        )

        let result = Result(
            meta: .init(
                toolchain: .init(path: typecheck.toolchain.swiftcPath, version: typecheck.toolchain.version),
                target: target,
                durationMs: durationMs
            ),
            compilerExitCode: typecheck.process.exitCode,
            missingSymbols: classification.symbols,
            rawDiagnostics: classification.unclassified,
            declaredIdentifiers: declaredIdentifiers.sorted()
        )

        let text = try renderJSON(result)
        return CallToolResult(content: [.text(text)], isError: false)
    }
}
