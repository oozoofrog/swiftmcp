import Foundation
import Testing
@testable import SwiftcMCPCore

@Suite("JSON-RPC envelope")
struct JSONRPCEnvelopeTests {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    @Test
    func requestRoundtrip() throws {
        let request = JSONRPCRequest(
            id: .integer(42),
            method: "ping",
            params: .object(["foo": .string("bar")])
        )
        let data = try encoder.encode(request)
        let decoded = try decoder.decode(JSONRPCRequest.self, from: data)
        #expect(decoded == request)
    }

    @Test
    func notificationHasNoId() throws {
        let json = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let inbound = try decoder.decode(JSONRPCInbound.self, from: Data(json.utf8))
        #expect(inbound.isNotification)
        #expect(inbound.id == nil)
        #expect(inbound.method == "notifications/initialized")
    }

    @Test
    func idStringDecode() throws {
        let json = #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#
        let inbound = try decoder.decode(JSONRPCInbound.self, from: Data(json.utf8))
        #expect(inbound.id == .string("abc"))
    }

    @Test
    func idIntegerDecode() throws {
        let json = #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#
        let inbound = try decoder.decode(JSONRPCInbound.self, from: Data(json.utf8))
        #expect(inbound.id == .integer(7))
    }

    @Test
    func responseSuccessShape() throws {
        let response = JSONRPCResponse.success(id: .integer(1), result: .object([:]))
        let data = try encoder.encode(response)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"result\""))
        #expect(!json.contains("\"error\""))
    }

    @Test
    func responseFailureShape() throws {
        let response = JSONRPCResponse.failure(id: .integer(1), error: .methodNotFound("foo"))
        let data = try encoder.encode(response)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"error\""))
        #expect(json.contains("-32601"))
        #expect(!json.contains("\"result\""))
    }

    @Test
    func parseErrorResponseHasNullId() throws {
        let response = JSONRPCResponse.failure(id: nil, error: .parseError())
        let data = try encoder.encode(response)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"id\":null"))
    }

    @Test
    func jsonValueRoundtripsAllVariants() throws {
        let value: JSONValue = .object([
            "null": .null,
            "bool": .bool(true),
            "int": .integer(-7),
            "double": .double(3.14),
            "string": .string("hi"),
            "array": .array([.integer(1), .string("x")])
        ])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }
}
