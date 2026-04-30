import Foundation

/// Arbitrary JSON value used for fields whose shape is method-specific.
public enum JSONValue: Sendable, Hashable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public extension JSONValue {
    /// Convenience for common dictionary access; returns nil if not an object or key absent.
    func member(_ key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    var asString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var asInt: Int? {
        switch self {
        case .integer(let value): return Int(exactly: value)
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    var asInt64: Int64? {
        switch self {
        case .integer(let value): return value
        case .double(let value): return Int64(value)
        default: return nil
        }
    }

    var asBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
