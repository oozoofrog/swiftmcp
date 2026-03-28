// RegistryCommand.swift
// `swiftmcp registry` 서브커맨드 그룹
// `swiftmcp registry show` — URL/캐시 정보/서버 수 출력
// `swiftmcp registry update` — 강제 갱신 (캐시 무시)

import ArgumentParser
import Foundation

/// registry show --json 출력용 Codable 모델
struct RegistryInfo: Codable, Sendable {
    let url: String
    let cacheDirectory: String
    let serverCount: Int
    let servers: [RegistryServerInfo]
}

/// registry show --json 서버 항목
struct RegistryServerInfo: Codable, Sendable {
    let name: String
    let description: String
    let repo: String
    let executable: String
}

/// 레지스트리 관리 커맨드 그룹
struct RegistryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "registry",
        abstract: "레지스트리 정보 표시 및 갱신.",
        subcommands: [ShowSubcommand.self, UpdateSubcommand.self],
        defaultSubcommand: ShowSubcommand.self
    )

    /// 레지스트리 정보 표시
    struct ShowSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "현재 레지스트리 정보를 표시합니다."
        )

        @Flag(name: .long, help: "JSON 형식으로 출력 (기계 판독 가능)")
        var json: Bool = false

        mutating func run() async throws {
            // stdout 기준 tty 감지 (결과를 stdout으로 출력하므로)
            let isTTY = ANSIStyle.isStdoutTTY
            let registryURL = RegistryClient.registryURL
            let cacheDir = RegistryClient.cacheDirectory

            // 레지스트리 로드 시도
            let registryClient = RegistryClient()
            let registry = try? await registryClient.fetch()

            // JSON 출력 모드
            if json {
                let serverList: [RegistryServerInfo] = (registry?.servers ?? [:])
                    .sorted(by: { $0.key < $1.key })
                    .map { name, entry in
                        RegistryServerInfo(
                            name: name,
                            description: entry.description,
                            repo: entry.repo,
                            executable: entry.executable
                        )
                    }
                let info = RegistryInfo(
                    url: registryURL,
                    cacheDirectory: cacheDir,
                    serverCount: registry?.servers.count ?? 0,
                    servers: serverList
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(info)
                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    print(jsonString)
                }
                return
            }

            if isTTY {
                print(ANSIStyle.bold + "레지스트리 정보:" + ANSIStyle.reset)
                print("  URL:        " + ANSIStyle.blue + registryURL + ANSIStyle.reset)
                print("  캐시 경로: \(cacheDir)")
            } else {
                print("레지스트리 정보:")
                print("  URL:        \(registryURL)")
                print("  캐시 경로: \(cacheDir)")
            }

            if let registry {
                let serverCount = registry.servers.count
                if isTTY {
                    print("  서버 수:   " + ANSIStyle.green + "\(serverCount)개" + ANSIStyle.reset)
                    print("")
                    print(ANSIStyle.bold + "등록된 서버:" + ANSIStyle.reset)
                } else {
                    print("  서버 수:   \(serverCount)개")
                    print("")
                    print("등록된 서버:")
                }
                for (name, entry) in registry.servers.sorted(by: { $0.key < $1.key }) {
                    if isTTY {
                        print("  " + ANSIStyle.green + name + ANSIStyle.reset + " — \(entry.description)")
                    } else {
                        print("  \(name) — \(entry.description)")
                    }
                }
            } else {
                print("  (레지스트리를 로드할 수 없습니다)")
            }
        }
    }

    /// 레지스트리 강제 갱신
    struct UpdateSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: "레지스트리를 강제 갱신합니다 (캐시 무시)."
        )

        mutating func run() async throws {
            let stderr = StderrWriter()
            stderr.write("레지스트리 갱신 중...")

            let registryClient = RegistryClient()
            do {
                // forceFetch: 캐시 무시하고 강제 갱신
                let registry = try await registryClient.forceFetch()
                stderr.write("레지스트리 갱신 완료. 서버 \(registry.servers.count)개 등록됨.")
            } catch {
                stderr.writeError("레지스트리 갱신 실패: \(error)")
                throw ExitCode.failure
            }
        }
    }
}
