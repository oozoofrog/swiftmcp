// TestCommand.swift
// `mcpswx test <name>` — MCP 서버 샌드박스 테스트 커맨드
// 임시 디렉토리에서 격리된 전체 라이프사이클 검증

import ArgumentParser
import Foundation

/// MCP 서버 샌드박스 테스트 커맨드
struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "MCP 서버 샌드박스 테스트 — 격리 환경에서 전체 라이프사이클 검증"
    )

    /// 테스트할 MCP 서버 이름
    @Argument(help: "테스트할 MCP 서버 이름 (레지스트리 등록명)")
    var name: String

    /// --sandbox 플래그: 임시 디렉토리 사용 (기본 동작, 명시적 지정 가능)
    @Flag(name: .customLong("sandbox"), help: "임시 디렉토리 격리 실행 (기본 동작)")
    var sandboxFlag: Bool = false

    /// --no-sandbox 플래그: 임시 디렉토리 비활성화
    @Flag(name: .customLong("no-sandbox"), help: "임시 디렉토리 격리 비활성화 (경고: 기존 캐시 오염 가능)")
    var noSandbox: Bool = false

    /// 실제 샌드박스 사용 여부 (--sandbox 또는 기본값 true, --no-sandbox가 false로 만듦)
    var sandbox: Bool { !noSandbox }

    /// MCP 서버 응답 대기 최대 시간 (초)
    @Option(name: .long, help: "MCP 서버 응답 대기 최대 시간 (초, 기본: 30)")
    var timeout: Int = 30

    /// tools/call 테스트에 사용할 tool 이름
    @Option(name: .long, help: "tools/call 테스트에 사용할 tool 이름 (미지정 시 첫 번째 tool 사용)")
    var tool: String? = nil

    func run() async throws {
        // --no-sandbox 경고
        if !sandbox {
            fputs("경고: --no-sandbox 모드입니다. 기존 ~/.mcpswx/ 캐시가 오염될 수 있습니다.\n", stderr)
        }

        let startTime = Date()
        let runner = MCPSandboxRunner(timeout: timeout, preferredTool: tool)

        do {
            try await runner.run(packageName: name, useSandbox: sandbox)
        } catch {
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
            fputs("\n실패: \(name) 테스트 실패 (\(elapsed)초)\n", stderr)
            fputs("  오류: \(error.localizedDescription)\n", stderr)
            throw ExitCode(1)
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
        fputs("\n테스트 완료: \(name) 모든 검증 통과 (\(elapsed)초)\n", stderr)
    }
}
