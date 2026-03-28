// SwiftMCP.swift
// swiftmcp — Swift MCP 플랫폼 런타임
//
// uvx/npx에 대응하는 Swift 전용 MCP 서버 러너.
// `swiftmcp run <name>` 한 줄로 MCP 서버를 즉시 실행.

import ArgumentParser
import Foundation

/// swiftmcp 루트 커맨드
@main
struct SwiftMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftmcp",
        abstract: "Swift MCP 플랫폼 — MCP 서버를 즉시 실행·설치·관리합니다.",
        usage: """
        swiftmcp <subcommand> [options]

        예제:
          swiftmcp run swift-yf-tools          # Yahoo Finance MCP 서버 즉시 실행
          swiftmcp install swift-yf-tools      # 명시적 설치 (실행 없음)
          swiftmcp search yahoo                # 레지스트리 검색
          swiftmcp list                        # 설치된 서버 목록
          swiftmcp init --name my-mcp          # 새 MCP 서버 프로젝트 생성
          swiftmcp mcp                         # swiftmcp 자체를 MCP 서버로 실행
        """,
        subcommands: [
            RunCommand.self,
            InstallCommand.self,
            ListCommand.self,
            SearchCommand.self,
            CacheCommand.self,
            RegistryCommand.self,
            InitCommand.self,
            MCPCommand.self,
            DoctorCommand.self,
            TestCommand.self,
        ],
        defaultSubcommand: nil
    )
}
