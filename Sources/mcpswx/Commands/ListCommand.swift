// ListCommand.swift
// `mcpswx list` 구현
// ~/.mcpswx/cache/ 디렉토리를 스캔하여 설치된 패키지 목록 출력

import ArgumentParser
import Foundation

/// 설치된 MCP 서버 목록을 출력하는 커맨드
struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "설치된 MCP 서버 목록을 출력합니다.",
        usage: "mcpswx list [--json]"
    )

    @Flag(name: .long, help: "JSON 형식으로 출력 (기계 판독 가능)")
    var json: Bool = false

    mutating func run() async throws {
        let cacheManager = CacheManager()
        let installedPackages = cacheManager.listInstalledPackages()

        if json {
            // JSON 출력 모드
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(installedPackages)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
            return
        }

        // 텍스트 출력 모드 (stdout 기준 tty 감지)
        let isTTY = ANSIStyle.isStdoutTTY

        if installedPackages.isEmpty {
            let message = "No packages installed."
            if isTTY {
                print(ANSIStyle.dim + message + ANSIStyle.reset)
            } else {
                print(message)
            }
            print("설치하려면: mcpswx install <name>")
            return
        }

        // 테이블 형식 출력
        if isTTY {
            print(ANSIStyle.bold + "설치된 MCP 서버:" + ANSIStyle.reset)
        } else {
            print("설치된 MCP 서버:")
        }

        let nameWidth = max(20, installedPackages.map { $0.name.count }.max() ?? 20)
        let versionWidth = max(10, installedPackages.map { $0.version.count }.max() ?? 10)

        // String.padding 사용 (Swift String과 안전하게 호환)
        let header = "이름".padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                   + "  "
                   + "버전".padding(toLength: versionWidth, withPad: " ", startingAt: 0)
                   + "  경로"
        let separator = String(repeating: "─", count: nameWidth + versionWidth + 50)

        if isTTY {
            print(ANSIStyle.dim + separator + ANSIStyle.reset)
            print(ANSIStyle.bold + header + ANSIStyle.reset)
            print(ANSIStyle.dim + separator + ANSIStyle.reset)
        } else {
            print(separator)
            print(header)
            print(separator)
        }

        for pkg in installedPackages {
            let namePadded = pkg.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let versionPadded = pkg.version.padding(toLength: versionWidth, withPad: " ", startingAt: 0)
            if isTTY {
                print(ANSIStyle.green + namePadded + ANSIStyle.reset
                    + "  " + versionPadded + "  " + pkg.binaryPath)
            } else {
                print(namePadded + "  " + versionPadded + "  " + pkg.binaryPath)
            }
        }
    }
}

/// 설치된 패키지 정보
struct InstalledPackage: Codable, Sendable {
    let name: String
    let version: String
    let binaryPath: String
}
