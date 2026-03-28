// SearchCommand.swift
// `mcpswx search <query>` 구현
// 레지스트리에서 name/description 필드 대소문자 무관 검색

import ArgumentParser
import Foundation

/// 검색 결과 JSON 출력용 Codable 모델
struct SearchResult: Codable, Sendable {
    let name: String
    let description: String
    let repo: String
    let executable: String
}

/// 레지스트리에서 MCP 서버를 검색하는 커맨드
struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "레지스트리에서 MCP 서버를 검색합니다.",
        usage: "mcpswx search <query> [--json]"
    )

    @Argument(help: "검색어 (이름 또는 설명에서 대소문자 무관 검색)")
    var query: String

    @Flag(name: .long, help: "JSON 형식으로 출력 (기계 판독 가능)")
    var json: Bool = false

    mutating func run() async throws {
        let stderr = StderrWriter()
        // stdout 기준 tty 감지 (결과를 stdout으로 출력하므로)
        let isTTY = ANSIStyle.isStdoutTTY

        // 레지스트리 로드
        let registryClient = RegistryClient()
        let registry: RegistryEntry
        do {
            registry = try await registryClient.fetch()
        } catch {
            stderr.writeError("레지스트리 로드 실패: \(error)")
            throw ExitCode.failure
        }

        // 대소문자 무관 검색
        let lowercasedQuery = query.lowercased()
        let results = registry.servers.filter { name, entry in
            name.lowercased().contains(lowercasedQuery) ||
            entry.description.lowercased().contains(lowercasedQuery)
        }

        // JSON 출력 모드
        if json {
            let searchResults = results.sorted(by: { $0.key < $1.key }).map { name, entry in
                SearchResult(
                    name: name,
                    description: entry.description,
                    repo: entry.repo,
                    executable: entry.executable
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(searchResults)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
            return
        }

        if results.isEmpty {
            let message = "No results found for '\(query)'."
            if isTTY {
                print(ANSIStyle.yellow + message + ANSIStyle.reset)
            } else {
                print(message)
            }
            return
        }

        // 결과 출력
        if isTTY {
            print(ANSIStyle.bold + "검색 결과 (\(results.count)개):" + ANSIStyle.reset)
        } else {
            print("검색 결과 (\(results.count)개):")
        }

        for (name, entry) in results.sorted(by: { $0.key < $1.key }) {
            if isTTY {
                print("")
                print("  " + ANSIStyle.green + ANSIStyle.bold + name + ANSIStyle.reset)
                print("  설명: " + entry.description)
                print("  저장소: " + ANSIStyle.blue + entry.repo + ANSIStyle.reset)
                print("  실행: " + ANSIStyle.dim + "mcpswx run \(name)" + ANSIStyle.reset)
            } else {
                print("")
                print("  \(name)")
                print("  설명: \(entry.description)")
                print("  저장소: \(entry.repo)")
                print("  실행: mcpswx run \(name)")
            }
        }
    }
}
