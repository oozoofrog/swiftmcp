import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("EmitAST (integration)")
struct EmitASTTests {
    private func writeTinySource() throws -> (CallScratch, URL) {
        let scratch = try CallScratch()
        let url = try scratch.write(name: "tiny.swift", contents: """
        func add(_ a: Int, _ b: Int) -> Int { a + b }
        let x = add(1, 2)
        """)
        return (scratch, url)
    }

    @Test
    func emitsTextAST() async throws {
        let (scratch, url) = try writeTinySource()
        defer { scratch.dispose() }

        let tool = EmitASTTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(url.path)])
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(EmitASTTool.Result.self, response)
        #expect(result.format == "text")
        #expect(result.formatUnstable == true)
        #expect(result.compilerExitCode == 0)
        #expect(result.bytes > 0)

        let body = try String(contentsOfFile: result.path, encoding: .utf8)
        #expect(body.contains("(source_file"))
    }

    @Test
    func emitsJSONAST() async throws {
        let (scratch, url) = try writeTinySource()
        defer { scratch.dispose() }

        let tool = EmitASTTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "input": .object(["file": .string(url.path)]),
            "format": .string("json")
        ]))

        let result = try decodeResult(EmitASTTool.Result.self, response)
        #expect(result.format == "json")
        let body = try String(contentsOfFile: result.path, encoding: .utf8)
        #expect(body.hasPrefix("{"))
    }

    @Test
    func unknownFormatReturnsInvalidParams() async throws {
        let tool = EmitASTTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([
                "input": .object(["file": .string("/tmp/x.swift")]),
                "format": .string("xml")
            ]))
        }
    }
}

func decodeResult<T: Decodable>(_ type: T.Type, _ response: CallToolResult) throws -> T {
    guard let text = response.content.first?.text else {
        throw MCPError.internalError("response has no text content")
    }
    return try JSONDecoder().decode(T.self, from: Data(text.utf8))
}
