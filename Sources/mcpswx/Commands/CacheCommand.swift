// CacheCommand.swift
// `mcpswx cache` 서브커맨드 그룹
// `mcpswx cache clean [--name <name>] [--yes]` 구현

import ArgumentParser
import Foundation

/// 캐시 관리 커맨드 그룹
struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "캐시 관리 커맨드.",
        subcommands: [CleanSubcommand.self],
        defaultSubcommand: CleanSubcommand.self
    )

    /// 캐시 정리 서브커맨드
    struct CleanSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clean",
            abstract: "캐시를 삭제합니다.",
            usage: "mcpswx cache clean [--name <name>] [--yes]"
        )

        @Option(name: .long, help: "삭제할 특정 패키지 이름 (미지정 시 전체 삭제)")
        var name: String?

        @Flag(name: .long, help: "확인 프롬프트 건너뜀")
        var yes: Bool = false

        mutating func run() async throws {
            let stderr = StderrWriter()
            let cacheManager = CacheManager()
            let isTTY = isatty(STDIN_FILENO) != 0

            let targetDesc = name.map { "'\($0)'" } ?? "전체 캐시"

            // 확인 프롬프트
            if !yes {
                if !isTTY {
                    // 비TTY 환경에서는 --yes 없이 삭제 불가
                    stderr.writeError("비대화형 환경에서는 --yes 플래그가 필요합니다.")
                    stderr.write("사용법: mcpswx cache clean --yes")
                    throw ExitCode.failure
                }
                print("\(targetDesc)를 삭제하시겠습니까? [y/N] ", terminator: "")
                guard let response = readLine(), response.lowercased() == "y" else {
                    stderr.write("취소되었습니다.")
                    return
                }
            }

            // 삭제 수행
            do {
                if let packageName = name {
                    try cacheManager.clean(name: packageName)
                    stderr.write("'\(packageName)' 캐시가 삭제되었습니다.")
                } else {
                    try cacheManager.cleanAll()
                    stderr.write("전체 캐시가 삭제되었습니다.")
                }
            } catch {
                stderr.writeError("캐시 삭제 실패: \(error)")
                throw ExitCode.failure
            }
        }
    }
}
