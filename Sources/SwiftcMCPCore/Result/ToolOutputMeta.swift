import Foundation

/// Metadata included in every tool result. Captures the toolchain we invoked, the target
/// triple (when applicable), and how long the tool spent producing the result.
///
/// JSON keys follow Swift property names (camelCase) per project policy: keeping the
/// MCP envelope (`protocolVersion`, etc.) and tool results on the same convention.
public struct ToolOutputMeta: Sendable, Codable, Equatable {
    public let toolchain: Toolchain
    public let target: String?
    public let durationMs: Int

    public struct Toolchain: Sendable, Codable, Equatable {
        public let path: String
        public let version: String

        public init(path: String, version: String) {
            self.path = path
            self.version = version
        }
    }

    public init(toolchain: Toolchain, target: String? = nil, durationMs: Int) {
        self.toolchain = toolchain
        self.target = target
        self.durationMs = durationMs
    }
}
