import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("Server lifecycle")
struct ServerLifecycleTests {
    @Test
    func initializeReturnsCapabilitiesAndServerInfo() async throws {
        let server = makeServer()
        let request = #"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"client","version":"1.0"}}}
        """#
        let responseData = try #require(await server.handleInbound(Data(request.utf8)))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)

        #expect(response.error == nil)
        let result = try #require(response.result)
        #expect(result.member("protocolVersion") == .string(MCPProtocolVersion))
        #expect(result.member("serverInfo")?.member("name") == .string("test"))
        #expect(result.member("capabilities")?.member("tools") != nil)
    }

    @Test
    func initializedNotificationDoesNotRespond() async throws {
        let server = makeServer()
        let notification = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let response = await server.handleInbound(Data(notification.utf8))
        #expect(response == nil)
        let state = await server.state
        #expect(state == .ready)
    }

    @Test
    func pingReturnsEmptyResult() async throws {
        let server = makeServer()
        let request = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let responseData = try #require(await server.handleInbound(Data(request.utf8)))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        #expect(response.error == nil)
        #expect(response.result == .object([:]))
    }

    @Test
    func unknownMethodReturnsMethodNotFound() async throws {
        let server = makeServer()
        let request = #"{"jsonrpc":"2.0","id":1,"method":"does_not_exist"}"#
        let responseData = try #require(await server.handleInbound(Data(request.utf8)))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        #expect(response.error?.code == -32601)
    }

    @Test
    func parseErrorReturnsNullIdResponse() async throws {
        let server = makeServer()
        let garbage = #"{"jsonrpc":"2.0",bogus"#
        let responseData = try #require(await server.handleInbound(Data(garbage.utf8)))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        #expect(response.error?.code == -32700)
        #expect(response.id == nil)
    }

    @Test
    func wrongJSONRPCVersionReturnsInvalidRequest() async throws {
        let server = makeServer()
        let request = #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#
        let responseData = try #require(await server.handleInbound(Data(request.utf8)))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        #expect(response.error?.code == -32600)
    }

    @Test
    func unknownNotificationIsSilentlyIgnored() async throws {
        let server = makeServer()
        let notification = #"{"jsonrpc":"2.0","method":"notifications/unknown_thing"}"#
        let response = await server.handleInbound(Data(notification.utf8))
        #expect(response == nil)
    }
}
