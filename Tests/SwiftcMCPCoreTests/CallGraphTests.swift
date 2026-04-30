import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("CallGraph (integration)")
struct CallGraphTests {
    private func writeSample() throws -> (CallScratch, URL) {
        let scratch = try CallScratch()
        let url = try scratch.write(name: "cg.swift", contents: """
        protocol P { func work() -> Int }
        class C: P { func work() -> Int { 1 } }
        class D: P { func work() -> Int { 2 } }

        func direct(_ a: Int, _ b: Int) -> Int { a + b }
        func dynamicCall(_ p: P) -> Int { p.work() }
        func makeAdder(_ x: Int) -> (Int) -> Int { { y in x + y } }

        let total = direct(1, 2) + dynamicCall(C()) + dynamicCall(D()) + makeAdder(5)(10)
        print(total)
        """)
        return (scratch, url)
    }

    @Test
    func emitsCallGraphWithDirectAndDynamicSites() async throws {
        let (scratch, url) = try writeSample()
        defer { scratch.dispose() }

        let tool = CallGraphTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object(["file": .string(url.path)]))

        #expect(response.isError == false)
        let result = try decodeResult(CallGraphTool.Result.self, response)
        #expect(result.compilerExitCode == 0)
        #expect(result.summary.totalFunctions > 0)
        #expect(result.summary.totalApplies > 0)
        // The protocol existential dispatch must yield at least one witness_method.
        let witnessTotal = result.functions.reduce(0) { $0 + $1.witnessMethod }
        #expect(witnessTotal > 0)
        // The closure capture must yield at least one partial_apply.
        let partialTotal = result.functions.reduce(0) { $0 + $1.partialApply }
        #expect(partialTotal > 0)
    }

    @Test
    func unknownOptimizationRaisesInvalidParams() async throws {
        let tool = CallGraphTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([
                "file": .string("/tmp/x.swift"),
                "optimization": .string("nope")
            ]))
        }
    }

    @Test
    func missingFileSurfacesAsCompilerError() async throws {
        let tool = CallGraphTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "file": .string("/tmp/swiftmcp-does-not-exist-\(UUID().uuidString).swift")
        ]))
        #expect(response.isError == false)
        let result = try decodeResult(CallGraphTool.Result.self, response)
        #expect(result.compilerExitCode != 0)
        #expect(result.summary.totalFunctions == 0)
    }
}
