import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("BuildIsolatedSnippet (integration)")
struct BuildIsolatedSnippetTests {
    @Test
    func successfulRunCapturesStdout() async throws {
        let tool = BuildIsolatedSnippetTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "code": .string("""
            print("hello")
            print("sum=\\([1, 2, 3].reduce(0, +))")
            """)
        ]))

        #expect(response.isError == false)
        let result = try decodeResult(BuildIsolatedSnippetTool.Result.self, response)
        #expect(result.buildExitCode == 0)
        #expect(result.timedOut == false)
        #expect(result.runExitCode == 0)
        let stdout = try #require(result.runStdout)
        #expect(stdout.contains("hello"))
        #expect(stdout.contains("sum=6"))
    }

    @Test
    func compileErrorReportedViaBuildExitCode() async throws {
        let tool = BuildIsolatedSnippetTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "code": .string("let x: Int = \"not an int\"")
        ]))

        #expect(response.isError == false) // compile diagnostic is success per policy
        let result = try decodeResult(BuildIsolatedSnippetTool.Result.self, response)
        #expect(result.buildExitCode != 0)
        #expect(result.runStdout == nil)
        #expect(result.runExitCode == nil)
        #expect(result.timedOut == false)
        let stderr = try #require(result.buildStderr)
        #expect(!stderr.isEmpty)
    }

    @Test
    func infiniteLoopTimesOut() async throws {
        let tool = BuildIsolatedSnippetTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "code": .string("while true { }"),
            "timeout_ms": .integer(1500)
        ]))

        #expect(response.isError == true)
        let result = try decodeResult(BuildIsolatedSnippetTool.Result.self, response)
        #expect(result.buildExitCode == 0)
        #expect(result.timedOut == true)
        let runDuration = try #require(result.runDurationMs)
        #expect(runDuration >= 1500)
    }

    @Test
    func argvPassesThroughToExecutable() async throws {
        let tool = BuildIsolatedSnippetTool(toolchain: ToolchainResolver())
        let response = try await tool.call(arguments: .object([
            "code": .string("""
            let args = CommandLine.arguments.dropFirst()
            print(args.joined(separator: ","))
            """),
            "args": .array([.string("a"), .string("b"), .string("c")])
        ]))

        let result = try decodeResult(BuildIsolatedSnippetTool.Result.self, response)
        let stdout = try #require(result.runStdout)
        #expect(stdout.contains("a,b,c"))
    }

    @Test
    func missingCodeRaisesInvalidParams() async throws {
        let tool = BuildIsolatedSnippetTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([:]))
        }
    }
}
