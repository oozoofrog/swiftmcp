import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("CompilerWarning parsing")
struct CompilerWarningTests {
    @Test
    func expressionWarning() throws {
        let line = "/tmp/probe.swift:2:18: warning: expression took 2ms to type-check (limit: 1ms)"
        let warning = try #require(CompilerWarning(line: line))
        #expect(warning.file == "/tmp/probe.swift")
        #expect(warning.line == 2)
        #expect(warning.column == 18)
        #expect(warning.kind == "expression")
        #expect(warning.subject == "expression")
        #expect(warning.durationMs == 2)
        #expect(warning.limitMs == 1)
    }

    @Test
    func globalFunctionWarning() throws {
        let line = "/tmp/probe.swift:1:6: warning: global function 'compute()' took 8ms to type-check (limit: 1ms)"
        let warning = try #require(CompilerWarning(line: line))
        #expect(warning.kind == "function")
        #expect(warning.subject == "global function 'compute()'")
        #expect(warning.durationMs == 8)
        #expect(warning.limitMs == 1)
    }

    @Test
    func instanceMethodWarning() throws {
        let line = "/x/y.swift:10:5: warning: instance method 'foo(_:)' took 12ms to type-check (limit: 5ms)"
        let warning = try #require(CompilerWarning(line: line))
        #expect(warning.kind == "function")
        #expect(warning.subject == "instance method 'foo(_:)'")
        #expect(warning.line == 10)
        #expect(warning.durationMs == 12)
    }

    @Test
    func initializerWarning() throws {
        let line = "/a.swift:3:1: warning: initializer 'init(x:)' took 7ms to type-check (limit: 1ms)"
        let warning = try #require(CompilerWarning(line: line))
        #expect(warning.kind == "function")
        #expect(warning.subject == "initializer 'init(x:)'")
    }

    @Test
    func nonWarningLineReturnsNil() {
        #expect(CompilerWarning(line: "") == nil)
        #expect(CompilerWarning(line: "1 | let x = 1") == nil)
        #expect(CompilerWarning(line: "/x.swift:1:1: error: something else") == nil)
        #expect(CompilerWarning(line: "/x.swift:1:1: warning: unrelated diagnostic") == nil)
    }
}
