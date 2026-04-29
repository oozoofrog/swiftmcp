import Foundation

/// JSON-RPC 2.0 message id — string or integer per spec.
public enum JSONRPCID: Sendable, Hashable, Equatable {
    case string(String)
    case integer(Int64)
}

extension JSONRPCID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON-RPC id must be string or integer"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        }
    }
}

public struct JSONRPCRequest: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONRPCID
    public let method: String
    public let params: JSONValue?

    public init(id: JSONRPCID, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

/// A single inbound message that may be either a request (id present) or a notification (id absent).
public struct JSONRPCInbound: Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let method: String
    public let params: JSONValue?

    public var isNotification: Bool { id == nil }
}

extension JSONRPCInbound: Codable {
    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try c.decode(String.self, forKey: .jsonrpc)
        self.id = try c.decodeIfPresent(JSONRPCID.self, forKey: .id)
        self.method = try c.decode(String.self, forKey: .method)
        self.params = try c.decodeIfPresent(JSONValue.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(method, forKey: .method)
        try c.encodeIfPresent(params, forKey: .params)
    }
}

public struct JSONRPCErrorObject: Sendable, Hashable, Equatable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

extension JSONRPCErrorObject: Codable {}

public extension JSONRPCErrorObject {
    static func parseError(_ message: String = "Parse error") -> JSONRPCErrorObject {
        .init(code: -32700, message: message)
    }
    static func invalidRequest(_ message: String = "Invalid Request") -> JSONRPCErrorObject {
        .init(code: -32600, message: message)
    }
    static func methodNotFound(_ method: String) -> JSONRPCErrorObject {
        .init(code: -32601, message: "Method not found: \(method)")
    }
    static func invalidParams(_ message: String) -> JSONRPCErrorObject {
        .init(code: -32602, message: message)
    }
    static func internalError(_ message: String) -> JSONRPCErrorObject {
        .init(code: -32603, message: message)
    }
}

/// JSON-RPC response — either result or error is present, never both.
/// Encoded with explicit `id: null` for parse-error cases (spec-compliant).
public struct JSONRPCResponse: Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let result: JSONValue?
    public let error: JSONRPCErrorObject?

    private init(id: JSONRPCID?, result: JSONValue?, error: JSONRPCErrorObject?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success(id: JSONRPCID, result: JSONValue) -> JSONRPCResponse {
        .init(id: id, result: result, error: nil)
    }

    public static func failure(id: JSONRPCID?, error: JSONRPCErrorObject) -> JSONRPCResponse {
        .init(id: id, result: nil, error: error)
    }
}

extension JSONRPCResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try c.decode(String.self, forKey: .jsonrpc)
        self.id = try c.decodeIfPresent(JSONRPCID.self, forKey: .id)
        self.result = try c.decodeIfPresent(JSONValue.self, forKey: .result)
        self.error = try c.decodeIfPresent(JSONRPCErrorObject.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        // id is encoded explicitly even when null (parse-error case)
        if let id {
            try c.encode(id, forKey: .id)
        } else {
            try c.encodeNil(forKey: .id)
        }
        if let result {
            try c.encode(result, forKey: .result)
        }
        if let error {
            try c.encode(error, forKey: .error)
        }
    }
}
