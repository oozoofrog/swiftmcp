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

/// Cancellation-aware tool: sleeps for a long time so the test can cancel mid-flight.
struct SlowTool: MCPTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "slow",
            description: "Sleeps for 60 seconds (cancellation-aware)",
            inputSchema: .object(["type": .string("object")])
        )
    }

    func call(arguments _: JSONValue?) async throws -> CallToolResult {
        try await Task.sleep(for: .seconds(60))
        return CallToolResult(content: [.text("done")])
    }
}

func makeServer(registry: ToolRegistry = ToolRegistry()) -> Server {
    Server(
        info: .init(name: "test", version: "0.0.1"),
        registry: registry
    )
}

/// Resolves `Tests/Fixtures/<name>/` relative to the source-file location of the caller.
/// Test targets don't own a resource bundle in this package, so fixtures are read by path.
func fixturePath(_ relative: String, file: StaticString = #filePath) -> String {
    let testFile = URL(fileURLWithPath: "\(file)", isDirectory: false)
    // Tests/SwiftcMCPCoreTests/<file>.swift  ->  Tests/Fixtures/<relative>
    let fixturesRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures", directoryHint: .isDirectory)
    return fixturesRoot.appending(path: relative).path
}
