// MCPSWX.swift
// mcpswx — Swift MCP 플랫폼 런타임
//
// uvx/npx에 대응하는 Swift 전용 MCP 서버 러너.
// `mcpswx run <name>` 한 줄로 MCP 서버를 즉시 실행.

import ArgumentParser
import Foundation

/// mcpswx 루트 커맨드
@main
struct MCPSWX: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcpswx",
        abstract: "Swift MCP 플랫폼 — MCP 서버를 즉시 실행·설치·관리합니다.",
        usage: """
        mcpswx <subcommand> [options]

        예제:
          mcpswx run swift-yf-tools          # Yahoo Finance MCP 서버 즉시 실행
          mcpswx install swift-yf-tools      # 명시적 설치 (실행 없음)
          mcpswx search yahoo                # 레지스트리 검색
          mcpswx list                        # 설치된 서버 목록
          mcpswx init --name my-mcp          # 새 MCP ��버 프로젝트 생���
          mcpswx mcp                         # mcpswx 자체를 MCP 서버로 실행
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
