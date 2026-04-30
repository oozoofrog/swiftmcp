import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("EmitSIL (integration)")
struct EmitSILTests {
    private func writeTinySource() throws -> (CallScratch, URL) {
        let scratch = try CallScratch()
        let url = try scratch.write(name: "tiny.swift", contents: """
        func add(_ a: Int, _ b: Int) -> Int { a + b }
        let x = add(1, 2)
        """)
        return (scratch, url)
    }

    @Test
    func canonicalSIL() async throws {
        let (scratch, url) = try writeTinySource()
        defer { scratch.dispose() }

        let tool = EmitSILTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object(["file": .string(url.path)]))

        let result = try decodeResult(EmitSILTool.Result.self, response)
        #expect(result.stage == "canonical")
        #expect(result.optimization == "none")
        #expect(result.bytes > 0)

        let body = try String(contentsOfFile: result.path, encoding: .utf8)
        #expect(body.contains("sil_stage canonical"))
    }

    @Test
    func rawSIL() async throws {
        let (scratch, url) = try writeTinySource()
        defer { scratch.dispose() }

        let tool = EmitSILTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "file": .string(url.path),
            "stage": .string("raw")
        ]))

        let result = try decodeResult(EmitSILTool.Result.self, response)
        #expect(result.stage == "raw")
        let body = try String(contentsOfFile: result.path, encoding: .utf8)
        #expect(body.contains("sil_stage raw"))
    }

    @Test
    func optimizedSpeed() async throws {
        let (scratch, url) = try writeTinySource()
        defer { scratch.dispose() }

        let tool = EmitSILTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "file": .string(url.path),
            "optimization": .string("speed")
        ]))

        let result = try decodeResult(EmitSILTool.Result.self, response)
        #expect(result.optimization == "speed")
    }

    @Test
    func unknownStageReturnsInvalidParams() async throws {
        let tool = EmitSILTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([
                "file": .string("/tmp/x.swift"),
                "stage": .string("nonsense")
            ]))
        }
    }
}
