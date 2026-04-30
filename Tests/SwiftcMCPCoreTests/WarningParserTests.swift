import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("WarningParser")
struct WarningParserTests {
    @Test
    func extractsWarningsAmongContextLines() {
        let stderr = """
        /tmp/probe.swift:2:18: warning: expression took 2ms to type-check (limit: 1ms)
        1 |
        2 |     let result = 1 + 2 + 3
          |                  `- warning: expression took 2ms to type-check (limit: 1ms)
        3 |     return result

        /tmp/probe.swift:1:6: warning: global function 'compute()' took 8ms to type-check (limit: 1ms)
        1 | func compute() -> Int {
          |      `- warning: global function 'compute()' took 8ms to type-check (limit: 1ms)
        """

        let parser = WarningParser()
        let warnings = parser.parse(stderr)

        #expect(warnings.count == 2)
        #expect(warnings[0].kind == "expression")
        #expect(warnings[1].kind == "function")
        #expect(warnings[1].subject.contains("compute()"))
    }

    @Test
    func emptyTextProducesNoWarnings() {
        #expect(WarningParser().parse("").isEmpty)
    }

    @Test
    func onlyContextLinesProducesNoWarnings() {
        let text = """
        1 | func foo() {
          | ^
        2 |     bar()
        """
        #expect(WarningParser().parse(text).isEmpty)
    }
}
