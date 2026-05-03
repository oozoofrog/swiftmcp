import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("DebugTimeParser")
struct DebugTimeParserTests {
    @Test
    func parsesFunctionAndExpressionLines() {
        let stderr = [
            "1.50ms\t/tmp/probe.swift:3:6\tglobal function probe.(file).slow1()@/tmp/probe.swift:3:6",
            "0.83ms\t/tmp/probe.swift:8:6\tglobal function probe.(file).slow2(x:)@/tmp/probe.swift:8:6",
            // 2-field expression timing line (no trailing subject) — what
            // `-debug-time-expression-type-checking` actually emits.
            "0.12ms\t/tmp/probe.swift:10:5",
            "<unknown>:0: error: unrelated diagnostic"
        ].joined(separator: "\n")

        let entries = DebugTimeParser().parse(stderr)

        #expect(entries.count == 3)
        #expect(entries[0].kind == "function")
        #expect(entries[0].durationMs == 1.50)
        #expect(entries[0].file == "/tmp/probe.swift")
        #expect(entries[0].line == 3)
        #expect(entries[0].column == 6)
        #expect(entries[1].subject.contains("slow2(x:)"))
        #expect(entries[2].kind == "expression")
        #expect(entries[2].subject.isEmpty)
        #expect(entries[2].durationMs == 0.12)
    }

    @Test
    func invalidLocLinesParseAsSyntheticEntries() {
        // Compiler-synthesized members (Codable derived, framework extension methods)
        // emit timing lines with `<invalid loc>` instead of a source location. Dropping
        // them would understate `totalMs` and per-kind counts.
        let withSubject = DebugTimeEntry(
            line: "0.04ms\t<invalid loc>\tstatic method FrogTray.(file).FrogTrayApp.$main()"
        )
        #expect(withSubject?.file == "<invalid loc>")
        #expect(withSubject?.line == 0)
        #expect(withSubject?.column == 0)
        #expect(withSubject?.kind == "function")
        #expect(withSubject?.durationMs == 0.04)

        let withoutSubject = DebugTimeEntry(line: "0.07ms\t<invalid loc>")
        #expect(withoutSubject?.file == "<invalid loc>")
        #expect(withoutSubject?.kind == "expression")
        #expect(withoutSubject?.durationMs == 0.07)
    }

    @Test
    func parsesMixedLocatedAndInvalidLocLines() {
        let stderr = [
            "1.50ms\t/x/Foo.swift:3:6\tglobal function Foo.(file).slow1()@/x/Foo.swift:3:6",
            "0.01ms\t<invalid loc>\tstatic method Foo.(file).Bar.CodingKeys.__derived_enum_equals",
            "0.02ms\t<invalid loc>\tinstance method Foo.(file).Bar.CodingKeys.hash(into:)",
            "0.12ms\t/x/Foo.swift:10:5",
            "noise line"
        ].joined(separator: "\n")
        let entries = DebugTimeParser().parse(stderr)
        #expect(entries.count == 4)
        let kinds = entries.map(\.kind)
        #expect(kinds.filter { $0 == "function" }.count == 3)
        #expect(kinds.filter { $0 == "expression" }.count == 1)
        let totalMs = entries.reduce(0.0) { $0 + $1.durationMs }
        #expect(abs(totalMs - 1.65) < 0.001)
    }

    @Test
    func operatorFunctionClassifiesAsFunction() {
        // `operator function` was missing from a hard-coded prefix list previously
        // and got mis-classified as expression. Structural classification (presence
        // of `(file).` decl locator) handles arbitrary kind keywords.
        let entry = DebugTimeEntry(
            line: "4.01ms\t/x/ContentView.swift:21:17\toperator function FrogTray.(file).TrayScreen.==@/x/ContentView.swift:21:17"
        )
        #expect(entry?.kind == "function")
        #expect(entry?.subject.hasPrefix("operator function") == true)
    }

    @Test
    func emptyTextProducesNoEntries() {
        #expect(DebugTimeParser().parse("").isEmpty)
    }

    @Test
    func nonTimingLinesAreSkipped() {
        let text = """
        warning: something happened
        /tmp/foo.swift:1:1: error: oops
        random noise
        """
        #expect(DebugTimeParser().parse(text).isEmpty)
    }

    @Test
    func decimalDurationsParseAsDouble() {
        let entry = DebugTimeEntry(
            line: "12.34ms\t/a/b.swift:1:2\tinstance method M.(file).Foo.bar()@/a/b.swift:1:2"
        )
        #expect(entry?.durationMs == 12.34)
        #expect(entry?.kind == "function")
    }
}
