import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("ConcurrencyAudit (integration)")
struct ConcurrencyAuditTests {
    private func writeViolatingSample() throws -> (CallScratch, URL) {
        let scratch = try CallScratch()
        let url = try scratch.write(name: "conc.swift", contents: """
        class NonSendableBox { var value: Int = 0 }

        func capture() -> () -> Int {
            let box = NonSendableBox()
            let closure: @Sendable () -> Int = {
                return box.value
            }
            return closure
        }

        actor Counter {
            var count: Int = 0
        }

        func leak(_ counter: Counter) {
            _ = counter.count
        }
        """)
        return (scratch, url)
    }

    private func writeCleanSample() throws -> (CallScratch, URL) {
        let scratch = try CallScratch()
        let url = try scratch.write(name: "clean.swift", contents: """
        func add(_ a: Int, _ b: Int) -> Int { a + b }
        let _ = add(1, 2)
        """)
        return (scratch, url)
    }

    @Test
    func violationsAreClassifiedByGroup() async throws {
        let (scratch, url) = try writeViolatingSample()
        defer { scratch.dispose() }

        let tool = ConcurrencyAuditTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "file": .string(url.path),
            "level": .string("complete")
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(ConcurrencyAuditTool.Result.self, response)
        #expect(result.summary.totalFindings > 0)

        // Per-group sum must equal totalFindings (unknown bucket included).
        let groupSum = result.summary.byGroup.values.reduce(0, +)
        #expect(groupSum == result.summary.totalFindings)

        // Concurrency violations include at least one warning or error.
        let problemCount = (result.summary.bySeverity["warning"] ?? 0) + (result.summary.bySeverity["error"] ?? 0)
        #expect(problemCount > 0)
    }

    @Test
    func cleanFileProducesNoFindings() async throws {
        let (scratch, url) = try writeCleanSample()
        defer { scratch.dispose() }

        let tool = ConcurrencyAuditTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "file": .string(url.path),
            "level": .string("complete")
        ]))
        let result = try decodeResult(ConcurrencyAuditTool.Result.self, response)
        #expect(result.summary.totalFindings == 0)
        #expect(result.compilerExitCode == 0)
    }

    @Test
    func minimalLevelReducesFindings() async throws {
        let (scratch, url) = try writeViolatingSample()
        defer { scratch.dispose() }

        let tool = ConcurrencyAuditTool(toolchain: ToolchainResolver())
        let complete = try await tool.call(arguments: .object([
            "file": .string(url.path),
            "level": .string("complete")
        ]))
        let minimal = try await tool.call(arguments: .object([
            "file": .string(url.path),
            "level": .string("minimal")
        ]))

        let completeResult = try decodeResult(ConcurrencyAuditTool.Result.self, complete)
        let minimalResult = try decodeResult(ConcurrencyAuditTool.Result.self, minimal)
        #expect(minimalResult.summary.totalFindings <= completeResult.summary.totalFindings)
    }

    @Test
    func missingFileSurfacesAsCompilerError() async throws {
        let tool = ConcurrencyAuditTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "file": .string("/tmp/swiftmcp-does-not-exist-\(UUID().uuidString).swift")
        ]))
        #expect(response.isError == false)
        let result = try decodeResult(ConcurrencyAuditTool.Result.self, response)
        #expect(result.compilerExitCode != 0)
        #expect(result.summary.totalFindings == 0)
    }

    @Test
    func missingArgumentRaisesInvalidParams() async throws {
        let tool = ConcurrencyAuditTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([:]))
        }
    }

    @Test
    func unknownLevelRaisesInvalidParams() async throws {
        let tool = ConcurrencyAuditTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([
                "file": .string("/tmp/x.swift"),
                "level": .string("aggressive")
            ]))
        }
    }
}
