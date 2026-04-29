import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("PrintTargetInfo (integration)")
struct PrintTargetInfoTests {
    @Test
    func resolvesSwiftcOnHost() async throws {
        let resolver = ToolchainResolver()
        let resolved = try await resolver.resolve()
        #expect(resolved.swiftcPath.hasSuffix("/swiftc"))
        #expect(!resolved.version.isEmpty)
    }

    @Test
    func resolveCachesResult() async throws {
        let resolver = ToolchainResolver()
        let first = try await resolver.resolve()
        let second = try await resolver.resolve()
        #expect(first == second)
    }

    @Test
    func validTripleReturnsJSON() async throws {
        let tool = PrintTargetInfoTool(toolchain: ToolchainResolver())
        let result = try await tool.call(
            arguments: .object(["target": .string("arm64-apple-macos14")])
        )
        #expect(result.isError == false)
        let text = try #require(result.content.first?.text)
        #expect(text.contains("\"target\"") || text.contains("\"triple\""))
    }

    @Test
    func invalidTripleSurfacesAsToolError() async throws {
        let tool = PrintTargetInfoTool(toolchain: ToolchainResolver())
        let result = try await tool.call(
            arguments: .object(["target": .string("not-a-real-triple")])
        )
        #expect(result.isError == true)
    }

    @Test
    func missingArgumentRaisesInvalidParams() async throws {
        let tool = PrintTargetInfoTool(toolchain: ToolchainResolver())
        await #expect(throws: MCPError.self) {
            try await tool.call(arguments: .object([:]))
        }
    }

    @Test
    func endToEndThroughServer() async throws {
        let registry = ToolRegistry()
        await registry.register(PrintTargetInfoTool(toolchain: ToolchainResolver()))
        let server = makeServer(registry: registry)

        let request = #"""
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"print_target_info","arguments":{"target":"arm64-apple-macos14"}}}
        """#
        let responseData = try #require(await server.handleInbound(Data(request.utf8)))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        #expect(response.error == nil)
        #expect(response.result?.member("isError") == .bool(false))
    }
}
