import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("FindSlowTypecheck (integration)")
struct FindSlowTypecheckTests {
    private func writeSource(_ contents: String) throws -> (CallScratch, URL) {
        let scratch = try CallScratch()
        let url = try scratch.write(name: "probe.swift", contents: contents)
        return (scratch, url)
    }

    @Test
    func warningsAtVeryLowThresholdProduceFindings() async throws {
        let (scratch, url) = try writeSource("""
        func compute() -> Int {
            let result = 1 + 2 + 3
            return result
        }
        let _ = compute()
        """)
        defer { scratch.dispose() }

        let tool = FindSlowTypecheckTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "file": .string(url.path),
            "expression_threshold_ms": .integer(1),
            "function_threshold_ms": .integer(1)
        ]))

        #expect(response.isError == false)
        let text = try #require(response.content.first?.text)
        let result = try JSONDecoder().decode(FindSlowTypecheckTool.Result.self, from: Data(text.utf8))
        #expect(result.findings.count > 0)
    }

    @Test
    func highThresholdProducesNoFindings() async throws {
        let (scratch, url) = try writeSource("""
        let x = 1 + 2
        """)
        defer { scratch.dispose() }

        let tool = FindSlowTypecheckTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "file": .string(url.path),
            "expression_threshold_ms": .integer(60_000),
            "function_threshold_ms": .integer(60_000)
        ]))

        let text = try #require(response.content.first?.text)
        let result = try JSONDecoder().decode(FindSlowTypecheckTool.Result.self, from: Data(text.utf8))
        #expect(result.findings.isEmpty)
        #expect(result.compilerExitCode == 0)
    }

    @Test
    func missingFileSurfacesAsCompilerError() async throws {
        let tool = FindSlowTypecheckTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "file": .string("/tmp/swiftmcp-does-not-exist-\(UUID().uuidString).swift")
        ]))

        // Tool result remains success; compiler diagnostics live in compilerExitCode.
        #expect(response.isError == false)
        let text = try #require(response.content.first?.text)
        let result = try JSONDecoder().decode(FindSlowTypecheckTool.Result.self, from: Data(text.utf8))
        #expect(result.compilerExitCode != 0)
        #expect(result.findings.isEmpty)
    }

    @Test
    func missingArgumentRaisesInvalidParams() async throws {
        let tool = FindSlowTypecheckTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([:]))
        }
    }
}
