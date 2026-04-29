import Foundation

/// Errors raised inside the MCP server. Mapped to the spec's two error channels:
/// - `invalidParams` / `methodNotFound` / `internalError` → JSON-RPC error response.
/// - `toolExecutionFailed` → tools/call result with `isError: true` and the message in content.
public enum MCPError: Error, Sendable, Equatable {
    case invalidParams(String)
    case methodNotFound(String)
    case internalError(String)
    case toolExecutionFailed(String)
}

public extension MCPError {
    var asJSONRPCError: JSONRPCErrorObject {
        switch self {
        case .invalidParams(let message):
            return .invalidParams(message)
        case .methodNotFound(let method):
            return .methodNotFound(method)
        case .internalError(let message):
            return .internalError(message)
        case .toolExecutionFailed(let message):
            // Should be caught and converted to a tool-result before reaching the JSON-RPC layer,
            // but if it leaks here, surface as internal error rather than masking.
            return .internalError(message)
        }
    }
}

/// A single MCP tool. Implementations live in `SwiftcMCPCore/Tools/`.
public protocol MCPTool: Sendable {
    var definition: ToolDefinition { get }
    func call(arguments: JSONValue?) async throws -> CallToolResult
}

public actor ToolRegistry {
    private var tools: [String: any MCPTool] = [:]

    public init() {}

    public func register(_ tool: any MCPTool) {
        tools[tool.definition.name] = tool
    }

    public func list() -> [ToolDefinition] {
        tools.values
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }

    public func call(name: String, arguments: JSONValue?) async throws -> CallToolResult {
        guard let tool = tools[name] else {
            throw MCPError.invalidParams("Unknown tool: \(name)")
        }
        return try await tool.call(arguments: arguments)
    }
}
