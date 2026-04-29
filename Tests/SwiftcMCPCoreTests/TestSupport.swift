import Foundation
@testable import SwiftcMCPCore

struct EchoTool: MCPTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "echo",
            description: "Echo back input text",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string")])
                ]),
                "required": .array([.string("text")])
            ])
        )
    }

    func call(arguments: JSONValue?) async throws -> CallToolResult {
        guard case .object(let dict) = arguments,
              case .string(let text) = dict["text"] else {
            throw MCPError.invalidParams("expected `text` argument")
        }
        return CallToolResult(content: [.text(text)])
    }
}

struct FailingTool: MCPTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "fail",
            description: "Always fails",
            inputSchema: .object(["type": .string("object")])
        )
    }

    func call(arguments _: JSONValue?) async throws -> CallToolResult {
        throw MCPError.toolExecutionFailed("intentional failure")
    }
}

func makeServer(registry: ToolRegistry = ToolRegistry()) -> Server {
    Server(
        info: .init(name: "test", version: "0.0.1"),
        registry: registry
    )
}
