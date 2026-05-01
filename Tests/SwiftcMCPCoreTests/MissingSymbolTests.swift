import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("MissingSymbolClassifier")
struct MissingSymbolClassifierTests {
    private func diag(
        _ message: String,
        line: Int = 1,
        column: Int = 1,
        severity: String = "error"
    ) -> CompilerDiagnostic {
        CompilerDiagnostic(
            file: "/tmp/x.swift",
            line: line,
            column: column,
            severity: severity,
            group: nil,
            message: message
        )
    }

    @Test
    func classifiesValueMissingSymbol() {
        let source = "func f() { unknownThing(1, 2) }"
        let output = MissingSymbolClassifier.classify(
            diagnostics: [diag("cannot find 'unknownThing' in scope", line: 1, column: 12)],
            sourceCode: source
        )
        #expect(output.symbols.count == 1)
        let symbol = output.symbols[0]
        #expect(symbol.name == "unknownThing")
        #expect(symbol.kind == .value)
        #expect(symbol.usagePattern == .call)
        #expect(symbol.falsePositive == false)
        #expect(output.unclassified.isEmpty)
    }

    @Test
    func classifiesTypeMissingSymbol() {
        let source = "let x: NotDefined = .init()"
        let output = MissingSymbolClassifier.classify(
            diagnostics: [diag("cannot find type 'NotDefined' in scope", line: 1, column: 8)],
            sourceCode: source
        )
        #expect(output.symbols.count == 1)
        #expect(output.symbols[0].name == "NotDefined")
        #expect(output.symbols[0].kind == .type)
        #expect(output.symbols[0].usagePattern == .typeAnnotation)
    }

    @Test
    func classifiesMissingModule() {
        let output = MissingSymbolClassifier.classify(
            diagnostics: [diag("no such module 'SomeRemote'", line: 1, column: 8)],
            sourceCode: "import SomeRemote"
        )
        #expect(output.symbols.count == 1)
        #expect(output.symbols[0].name == "SomeRemote")
        #expect(output.symbols[0].kind == .module)
        #expect(output.symbols[0].usagePattern == .importStatement)
    }

    @Test
    func valueUsageDetectsMemberAccess() {
        let source = "let result = thing.value"
        let output = MissingSymbolClassifier.classify(
            diagnostics: [diag("cannot find 'thing' in scope", line: 1, column: 14)],
            sourceCode: source
        )
        #expect(output.symbols[0].usagePattern == .memberAccess)
    }

    @Test
    func valueUsageFallsBackToUnknownForBareReference() {
        let source = "let result = bareValue"
        let output = MissingSymbolClassifier.classify(
            diagnostics: [diag("cannot find 'bareValue' in scope", line: 1, column: 14)],
            sourceCode: source
        )
        #expect(output.symbols[0].usagePattern == .unknown)
    }

    @Test
    func declaredIdentifierTriggersFalsePositive() {
        let source = "func f(_ a: Int, _ b: Int) { _ = b }"
        let output = MissingSymbolClassifier.classify(
            diagnostics: [diag("cannot find 'b' in scope", line: 1, column: 34)],
            sourceCode: source,
            declaredIdentifiers: ["a", "b", "f"]
        )
        #expect(output.symbols.count == 1)
        #expect(output.symbols[0].falsePositive == true)
    }

    @Test
    func mergesDuplicateLocations() {
        let source = "let x = unknownFunc(); let y = unknownFunc()"
        let output = MissingSymbolClassifier.classify(
            diagnostics: [
                diag("cannot find 'unknownFunc' in scope", line: 1, column: 9),
                diag("cannot find 'unknownFunc' in scope", line: 1, column: 32)
            ],
            sourceCode: source
        )
        #expect(output.symbols.count == 1)
        #expect(output.symbols[0].locations.count == 2)
    }

    @Test
    func unrelatedDiagnosticsLandInUnclassified() {
        let output = MissingSymbolClassifier.classify(
            diagnostics: [diag("type 'Int' is not convertible to 'String'")],
            sourceCode: "let x: String = 1"
        )
        #expect(output.symbols.isEmpty)
        #expect(output.unclassified.count == 1)
    }

    @Test
    func warningsAreAlwaysUnclassifiedNotMissingSymbols() {
        // Even if a warning's message matches the pattern, only `error` severity
        // counts as a missing symbol (warnings could be deprecation, etc.).
        let output = MissingSymbolClassifier.classify(
            diagnostics: [diag("cannot find 'X' in scope", severity: "warning")],
            sourceCode: ""
        )
        #expect(output.symbols.isEmpty)
        #expect(output.unclassified.count == 1)
    }
}

@Suite("ASTIdentifierExtractor")
struct ASTIdentifierExtractorTests {
    @Test
    func extractsParameterNames() {
        let ast = """
        (func_decl decl_context=0x1 range=[/x.swift:1:1 - line:1:1] "f(_:_:)" interface_type="(Int, Int) -> Int"
          (parameter_list
            (parameter "a" decl_context=0x2)
            (parameter "b" decl_context=0x2)))
        """
        let ids = ASTIdentifierExtractor.extractDeclaredIdentifiers(astText: ast)
        #expect(ids.contains("a"))
        #expect(ids.contains("b"))
    }

    @Test
    func extractsFunctionBaseName() {
        let ast = #"(func_decl decl_context=0x1 range=[/x.swift:1:1 - line:1:1] "helloAdd(_:_:)" interface_type="(Int, Int) -> Int")"#
        let ids = ASTIdentifierExtractor.extractDeclaredIdentifiers(astText: ast)
        #expect(ids.contains("helloAdd"))
        #expect(ids.contains("helloAdd(_:_:)") == false)
    }

    @Test
    func extractsTypeDeclarations() {
        let ast = """
        (struct_decl decl_context=0x1 range=[/x.swift:1:1 - line:1:5] "Counter" interface_type="Counter.Type"
          (var_decl …))
        (class_decl decl_context=0x2 range=[/x.swift:2:1 - line:2:5] "Box")
        (enum_decl decl_context=0x3 range=[/x.swift:3:1 - line:3:5] "Color")
        (typealias_decl decl_context=0x4 "Index")
        """
        let ids = ASTIdentifierExtractor.extractDeclaredIdentifiers(astText: ast)
        #expect(ids.contains("Counter"))
        #expect(ids.contains("Box"))
        #expect(ids.contains("Color"))
        #expect(ids.contains("Index"))
    }

    @Test
    func extractsImportModuleNames() {
        let ast = #"(import_decl decl_context=0x1 range=[/x.swift:1:1 - line:1:8] module="Foundation")"#
        let ids = ASTIdentifierExtractor.extractDeclaredIdentifiers(astText: ast)
        #expect(ids.contains("Foundation"))
    }

    @Test
    func extractsLetBindings() {
        let ast = #"(pattern_named type="_" "result")"#
        let ids = ASTIdentifierExtractor.extractDeclaredIdentifiers(astText: ast)
        #expect(ids.contains("result"))
    }

    @Test
    func emptyInputReturnsEmptySet() {
        #expect(ASTIdentifierExtractor.extractDeclaredIdentifiers(astText: "").isEmpty)
    }

    @Test
    func nonMatchingLinesAreIgnored() {
        let ids = ASTIdentifierExtractor.extractDeclaredIdentifiers(
            astText: "this is not an AST line\n(some_other_decl …)\n"
        )
        #expect(ids.isEmpty)
    }
}
