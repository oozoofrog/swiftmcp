// MCPCommand.swift
// `mcpswx mcp` 서브커맨드
// mcpswx 자체를 MCP 서버로 실행 (JSON-RPC 2.0, stdio)

import ArgumentParser
import Foundation

/// mcpswx 자체를 MCP 서버로 실행하는 커맨드
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "mcpswx을 MCP 서버 모드로 실행합니다 (JSON-RPC 2.0 over stdio).",
        usage: "mcpswx mcp"
    )

    mutating func run() async throws {
        let handler = MCPServerHandler()
        try await handler.serve()
    }
}
