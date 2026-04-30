import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("CompilerDiagnostic parsing")
struct CompilerDiagnosticTests {
    @Test
    func warningWithGroupSuffix() throws {
        let line = "/x.swift:6:16: warning: capture of 'box' with non-Sendable type 'NonSendableBox' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]"
        let d = try #require(CompilerDiagnostic(line: line))
        #expect(d.file == "/x.swift")
        #expect(d.line == 6)
        #expect(d.column == 16)
        #expect(d.severity == "warning")
        #expect(d.group == "SendableClosureCaptures")
        #expect(d.message.hasPrefix("capture of 'box'"))
    }

    @Test
    func errorWithoutGroup() throws {
        let line = "/x.swift:16:17: error: actor-isolated property 'count' can not be referenced from a nonisolated context"
        let d = try #require(CompilerDiagnostic(line: line))
        #expect(d.severity == "error")
        #expect(d.group == nil)
        #expect(d.message.contains("actor-isolated"))
    }

    @Test
    func noteSeverityIsRecognized() throws {
        let line = "/x.swift:1:7: note: class 'NonSendableBox' does not conform to the 'Sendable' protocol"
        let d = try #require(CompilerDiagnostic(line: line))
        #expect(d.severity == "note")
    }

    @Test
    func contextOnlyLinesAreSkipped() {
        #expect(CompilerDiagnostic(line: " 1 | class NonSendableBox { var value: Int = 0 }") == nil)
        #expect(CompilerDiagnostic(line: "   |       `- note: class 'X' does not conform") == nil)
    }

    @Test
    func footnoteLinesAreSkipped() {
        let footnote = "[#SendableClosureCaptures]: <https://docs.swift.org/compiler/documentation/diagnostics/sendable-closure-captures>"
        #expect(CompilerDiagnostic(line: footnote) == nil)
    }

    @Test
    func parserExtractsAcrossMultiline() {
        let stderr = """
        /x.swift:6:16: warning: capture issue [#SendableClosureCaptures]
         1 | class X { }
           | ^
        /x.swift:16:17: error: actor-isolated property 'count' can not be referenced from a nonisolated context
        [#SendableClosureCaptures]: <https://...>
        """
        let parser = DiagnosticParser()
        let diagnostics = parser.parse(stderr)
        #expect(diagnostics.count == 2)
        #expect(diagnostics[0].severity == "warning")
        #expect(diagnostics[0].group == "SendableClosureCaptures")
        #expect(diagnostics[1].severity == "error")
        #expect(diagnostics[1].group == nil)
    }
}
