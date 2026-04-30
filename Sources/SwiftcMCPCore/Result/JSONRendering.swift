import Foundation

/// Serialize a Codable result for inclusion as `text` content in a tool response.
/// Pretty-printed with sorted keys so output is stable for snapshot-style inspection.
func renderJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? "{}"
}
