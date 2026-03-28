// InstallCommand.swift
// `mcpswx install <name>` 구현
// 실행 없이 다운로드·캐싱만 수행

import ArgumentParser
import Foundation

/// MCP 서버를 명시적으로 설치하는 커맨드 (실행하지 않음)
struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "MCP 서버를 다운로드하여 캐시에 설치합니다 (실행하지 않음).",
        usage: "mcpswx install <name>"
    )

    @Argument(help: "설치할 MCP 서버 이름 (레지스트리에 등록된 이름)")
    var name: String

    mutating func run() async throws {
        let stderr = StderrWriter()

        // 레지스트리 로드
        stderr.write("레지스트리에서 '\(name)' 조회 중...")
        let registryClient = RegistryClient()
        let registry: RegistryEntry
        do {
            registry = try await registryClient.fetch()
        } catch {
            stderr.writeError("레지스트리 로드 실패: \(error)")
            throw ExitCode.failure
        }

        guard let serverEntry = registry.servers[name] else {
            stderr.writeError("Package not found in registry: '\(name)'")
            stderr.write("Try: mcpswx search <query>")
            throw ExitCode.failure
        }

        // 바이너리 URL 확인
        let binaryResolver = BinaryResolver()
        let cacheManager = CacheManager()

        let resolvedInfo: (url: URL, version: String)
        do {
            resolvedInfo = try await binaryResolver.resolve(entry: serverEntry)
        } catch {
            stderr.writeError("바이너리를 찾을 수 없습니다: \(error)")
            throw ExitCode.failure
        }

        let version = resolvedInfo.version
        let downloadURL = resolvedInfo.url

        // 이미 설치된 경우 확인
        if let cachedPath = cacheManager.cachedBinaryPath(name: name, version: version) {
            stderr.write("'\(name)@\(version)'이 이미 설치되어 있습니다.")
            print("설치 경로: \(cachedPath)")
            return
        }

        // 다운로드
        stderr.write("Downloading '\(name)@\(version)'...")
        do {
            let binaryPath = try await cacheManager.download(
                url: downloadURL,
                name: name,
                version: version,
                executableName: serverEntry.executable
            )
            stderr.write("설치 완료!")
            // 설치 경로는 stdout에 출력 (스크립트에서 파싱 가능하도록)
            print("Installed to: \(binaryPath)")
        } catch {
            stderr.writeError("설치 실패: \(error)")
            throw ExitCode.failure
        }
    }
}
