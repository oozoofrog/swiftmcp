import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("Tools dispatch")
struct ToolsDispatchTests {
    @Test
    func listEmptyRegistry() async throws {
        let server = makeServer()
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let responseData = try #require(await server.handleInbound(Data(request.utf8)))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)

        #expect(response.error == nil)
        guard case .array(let tools) = response.result?.member("tools") else {
            Issue.record("result.tools is not an array")
            return
        }
        #expect(tools.isEmpty)
    }

    @Test
    func listWithRegisteredTool() async throws {
        let registry = ToolRegistry()
        await registry.register(EchoTool())
        let server = makeServer(registry: registry)
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let responseData = try #require(await server.handleInbound(Data(request.utf8)))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)

        guard case .array(let tools) = response.result?.member("tools"), tools.count == 1 else {
            Issue.record("expected exactly 1 tool")
            return
        }
        #expect(tools[0].member("name") == .string("echo"))
        #expect(tools[0].member("description") == .string("Echo back input text"))
    }

    @Test
    func callUnknownToolReturnsInvalidParams() async throws {
        let server = makeServer()
        let request = #"""
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"missing","arguments":{}}}
        """#
        let responseData = try #require(await server.handleInbound(Data(request.utf8)))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        #expect(response.error?.code == -32602)
    }

    @Test
    func callMissingNameReturnsInvalidParams() async throws {
        let server = makeServer()
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#
        let responseData = try #require(await server.handleInbound(Data(request.utf8)))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        #expect(response.error?.code == -32602)
    }

    @Test
    func callSuccessReturnsTextContent() async throws {
        let registry = ToolRegistry()
        await registry.register(EchoTool())
        let server = makeServer(registry: registry)
        let request = #"""
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"}}}
        """#
        let responseData = try #require(await server.handleInbound(Data(request.utf8)))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)

        #expect(response.error == nil)
        guard case .array(let content) = response.result?.member("content"), content.count == 1 else {
            Issue.record("expected exactly 1 content item")
            return
        }
        #expect(content[0].member("type") == .string("text"))
        #expect(content[0].member("text") == .string("hello"))
        #expect(response.result?.member("isError") == .bool(false))
    }

    @Test
    func toolExecutionFailureBecomesIsErrorResult() async throws {
        let registry = ToolRegistry()
        await registry.register(FailingTool())
        let server = makeServer(registry: registry)
        let request = #"""
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fail","arguments":{}}}
        """#
        let responseData = try #require(await server.handleInbound(Data(request.utf8)))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)

        // Tool execution failures are NOT JSON-RPC errors per the channel-mapping policy.
        #expect(response.error == nil)
        #expect(response.result?.member("isError") == .bool(true))
        guard case .array(let content) = response.result?.member("content"), content.count == 1 else {
            Issue.record("expected exactly 1 content item")
            return
        }
        #expect(content[0].member("text") == .string("intentional failure"))
    }
}
