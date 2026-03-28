// DoctorCommand.swift
// `mcpswx doctor` — 환경 진단 커맨드
// ANSI 컬러 기호 출력, TTY 비연결 시 plain text, --json 지원
// 실패 항목 존재 시 exit(1) 반환

import ArgumentParser
import Foundation

/// 환경 진단 커맨드
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "환경 진단 — Swift 툴체인, 네트워크, 레지스트리, 캐시, 설치 서버 상태 확인"
    )

    /// JSON 출력 모드 (stdout으로 DoctorResult 배열 출력)
    @Flag(name: .long, help: "진단 결과를 JSON 형식으로 stdout에 출력")
    var json: Bool = false

    func run() async throws {
        // 진단 체커 목록
        let checkers: [any DoctorCheck] = [
            SwiftToolchainChecker(),
            NetworkChecker(),
            RegistryChecker(),
            CacheChecker(),
            InstalledServerChecker(),
        ]

        // 모든 체커 순차 실행
        var allResults: [DoctorResult] = []

        if !json {
            fputs("mcpswx doctor\n\n환경 진단 결과:\n", stderr)
        }

        for checker in checkers {
            let results = await checker.run()
            allResults.append(contentsOf: results)

            if !json {
                for result in results {
                    let line = formatResult(result)
                    fputs("  \(line)\n", stderr)
                }
            }
        }

        // JSON 출력 모드
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(allResults),
               let jsonStr = String(data: data, encoding: .utf8) {
                print(jsonStr)
            }
            return
        }

        // 요약 출력
        let passCount = allResults.filter { $0.status == .pass }.count
        let warnCount = allResults.filter { $0.status == .warning }.count
        let failCount = allResults.filter { $0.status == .fail }.count

        fputs("\n진단 완료: \(passCount) pass, \(warnCount) warning, \(failCount) fail\n", stderr)

        // 실패 항목이 있으면 exit(1)
        if failCount > 0 {
            throw ExitCode(1)
        }
    }

    // MARK: - 포매터

    /// 진단 결과 한 줄 포맷 (ANSI 컬러, 비TTY 시 plain text)
    private func formatResult(_ result: DoctorResult) -> String {
        let isTTY = isatty(STDERR_FILENO) != 0

        let badge: String
        let prefix: String

        switch result.status {
        case .pass:
            if isTTY {
                badge = ANSIStyle.green + "[PASS]" + ANSIStyle.reset
            } else {
                badge = "[PASS]"
            }
            prefix = ""
        case .fail:
            if isTTY {
                badge = ANSIStyle.red + "[FAIL]" + ANSIStyle.reset
            } else {
                badge = "[FAIL]"
            }
            prefix = ""
        case .warning:
            if isTTY {
                badge = ANSIStyle.yellow + "[WARN]" + ANSIStyle.reset
            } else {
                badge = "[WARN]"
            }
            prefix = ""
        }

        _ = prefix
        return "\(badge) \(result.name): \(result.message)"
    }
}
