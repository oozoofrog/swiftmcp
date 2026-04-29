import Foundation

/// Decode `JSONValue` payload into a typed Decodable.
/// Round-trips through JSON data; acceptable here because MCP request volume is low.
func decodeParams<T: Decodable>(_ params: JSONValue?) throws -> T {
    guard let params else {
        throw MCPError.invalidParams("Missing params")
    }
    do {
        let data = try JSONEncoder().encode(params)
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        throw MCPError.invalidParams("Failed to decode params: \(error)")
    }
}

/// Best-effort optional decode: returns nil for missing or empty params.
func decodeOptionalParams<T: Decodable>(_ params: JSONValue?) throws -> T? {
    guard let params else { return nil }
    if case .object(let dict) = params, dict.isEmpty {
        return nil
    }
    do {
        let data = try JSONEncoder().encode(params)
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        throw MCPError.invalidParams("Failed to decode params: \(error)")
    }
}

/// Encode a typed Encodable to `JSONValue`.
func encodeJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    do {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
        throw MCPError.internalError("Failed to encode result: \(error)")
    }
}
