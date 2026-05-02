import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("EmitIR (integration)")
struct EmitIRTests {
    private func writeTinySource() throws -> (CallScratch, URL) {
        let scratch = try CallScratch()
        let url = try scratch.write(name: "tiny.swift", contents: """
        func add(_ a: Int, _ b: Int) -> Int { a + b }
        let x = add(1, 2)
        """)
        return (scratch, url)
    }

    @Test
    func textIR() async throws {
        let (scratch, url) = try writeTinySource()
        defer { scratch.dispose() }

        let tool = EmitIRTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(url.path)])
        ]))

        let result = try decodeResult(EmitIRTool.Result.self, response)
        #expect(result.stage == "ir")
        #expect(result.isBinary == false)
        #expect(result.bytes > 0)

        let body = try String(contentsOfFile: result.path, encoding: .utf8)
        #expect(body.contains("ModuleID") || body.contains("source_filename"))
    }

    @Test
    func bitcodeIsBinary() async throws {
        let (scratch, url) = try writeTinySource()
        defer { scratch.dispose() }

        let tool = EmitIRTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(url.path)]),
            "stage": .string("bc")
        ]))

        let result = try decodeResult(EmitIRTool.Result.self, response)
        #expect(result.stage == "bc")
        #expect(result.isBinary == true)
        #expect(result.bytes > 0)
    }

    @Test
    func unknownStageReturnsInvalidParams() async throws {
        let tool = EmitIRTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([
                "input": .object(["file": .string("/tmp/x.swift")]),
                "stage": .string("nope")
            ]))
        }
    }
}
