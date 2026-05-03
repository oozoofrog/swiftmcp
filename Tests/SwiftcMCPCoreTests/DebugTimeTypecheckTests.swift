import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("DebugTimeTypecheck (integration)")
struct DebugTimeTypecheckTests {
    private func writeSource(_ contents: String) throws -> (CallScratch, URL) {
        let scratch = try CallScratch()
        let url = try scratch.write(name: "probe.swift", contents: contents)
        return (scratch, url)
    }

    @Test
    func emitsTimingsForFunctionBodies() async throws {
        let (scratch, url) = try writeSource("""
        func compute() -> Int {
            let result = 1 + 2 + 3
            return result
        }
        let _ = compute()
        """)
        defer { scratch.dispose() }

        let tool = DebugTimeTypecheckTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(url.path)])
        ]))

        #expect(response.isError == false)
        let text = try #require(response.content.first?.text)
        let result = try JSONDecoder().decode(DebugTimeTypecheckTool.Result.self, from: Data(text.utf8))
        #expect(result.totalEntries > 0)
        #expect(result.compilerExitCode == 0)
        let functionEntries = result.topEntries.filter { $0.kind == "function" }
        #expect(!functionEntries.isEmpty)
    }

    @Test
    func minMsThresholdFiltersEntries() async throws {
        let (scratch, url) = try writeSource("""
        func a() -> Int { return 1 + 2 }
        func b() -> Int { return 3 + 4 }
        let _ = a() + b()
        """)
        defer { scratch.dispose() }

        let tool = DebugTimeTypecheckTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(url.path)]),
            "min_ms": .double(60_000)
        ]))

        let text = try #require(response.content.first?.text)
        let result = try JSONDecoder().decode(DebugTimeTypecheckTool.Result.self, from: Data(text.utf8))
        #expect(result.totalEntries == 0)
        #expect(result.topEntries.isEmpty)
    }

    @Test
    func topCapBoundsResponse() async throws {
        let (scratch, url) = try writeSource("""
        func a() -> Int { 1 }
        func b() -> Int { 2 }
        func c() -> Int { 3 }
        let _ = a() + b() + c()
        """)
        defer { scratch.dispose() }

        let tool = DebugTimeTypecheckTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(url.path)]),
            "top": .integer(1)
        ]))

        let text = try #require(response.content.first?.text)
        let result = try JSONDecoder().decode(DebugTimeTypecheckTool.Result.self, from: Data(text.utf8))
        #expect(result.returnedEntries == 1)
        #expect(result.topEntries.count == 1)
        #expect(result.totalEntries >= 1)
    }

    @Test
    func missingFileRejectedByResolver() async throws {
        let tool = DebugTimeTypecheckTool(toolchain: ToolchainResolver())
        let bogus = "/tmp/swiftmcp-debug-time-missing-\(UUID().uuidString).swift"
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([
                "input": .object(["file": .string(bogus)])
            ]))
        }
    }

    @Test
    func missingArgumentRaisesInvalidParams() async throws {
        let tool = DebugTimeTypecheckTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([:]))
        }
    }
}
