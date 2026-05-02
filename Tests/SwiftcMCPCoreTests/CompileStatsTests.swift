import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("CompileStats (integration)")
struct CompileStatsTests {
    private func writeSample() throws -> (CallScratch, URL) {
        let scratch = try CallScratch()
        let url = try scratch.write(name: "sample.swift", contents: """
        import Foundation

        func compute(_ values: [Int]) -> Int {
            values.reduce(0, +)
        }

        let result = compute([1, 2, 3, 4, 5])
        print(result)
        """)
        return (scratch, url)
    }

    @Test
    func returnsCountersAndCategories() async throws {
        let (scratch, url) = try writeSample()
        defer { scratch.dispose() }

        let tool = CompileStatsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(url.path)])
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(CompileStatsTool.Result.self, response)
        #expect(result.totalCounters > 0)
        #expect(result.topCounters.isEmpty == false)
        #expect(result.compilerExitCode == 0)

        // The frontend always emits Sema and AST counters for any non-trivial source.
        #expect(result.byCategory["Sema"] != nil)
        #expect(result.byCategory["AST"] != nil)
    }

    @Test
    func topRespectsRequestedSize() async throws {
        let (scratch, url) = try writeSample()
        defer { scratch.dispose() }

        let tool = CompileStatsTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(url.path)]),
            "top": .integer(5)
        ]))
        let result = try decodeResult(CompileStatsTool.Result.self, response)
        #expect(result.topCounters.count == 5)
        // Top counters should be in descending order by value.
        for pair in zip(result.topCounters, result.topCounters.dropFirst()) {
            #expect(pair.0.value >= pair.1.value)
        }
    }

    @Test
    func missingFileRejectedByResolver() async throws {
        let tool = CompileStatsTool(toolchain: ToolchainResolver())
        let bogus = "/tmp/swiftmcp-does-not-exist-\(UUID().uuidString).swift"
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([
                "input": .object(["file": .string(bogus)])
            ]))
        }
    }

    @Test
    func missingArgumentRaisesInvalidParams() async throws {
        let tool = CompileStatsTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([:]))
        }
    }
}
