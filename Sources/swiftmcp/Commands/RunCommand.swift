// RunCommand.swift
// `swiftmcp run <name> [-- args...]` 구현
// 핵심 플로우: 레지스트리 조회 → BinaryResolver → CacheManager → ProcessRunner

import ArgumentParser
import Foundation

/// MCP 서버를 즉시 실행하는 커맨드
struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "레지스트리에서 MCP 서버를 즉시 실행합니다.",
        usage: "swiftmcp run <name> [-- <server-args>...]"
    )

    @Argument(help: "실행할 MCP 서버 이름 (레지스트리에 등록된 이름)")
    var name: String

    /// `--` 이후에 전달된 인수 (하위 프로세스로 패스스루)
    @Argument(parsing: .captureForPassthrough, help: ArgumentHelp("MCP 서버에 전달할 추가 인수 (-- 이후)"))
    var passthroughArguments: [String] = []

    mutating func run() async throws {
        let stderr = StderrWriter()

        // 서버 인수 결합: 레지스트리 args + 사용자 passthrough
        func buildArguments(for entry: ServerEntry) -> [String] {
            (entry.args ?? []) + passthroughArguments
        }

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
            stderr.write("Try: swiftmcp search <query>")
            throw ExitCode.failure
        }

        // 캐시 확인
        let cacheManager = CacheManager()
        let binaryResolver = BinaryResolver()

        // 버전 및 바이너리 URL 확인
        let resolvedInfo: (url: URL, version: String)
        do {
            resolvedInfo = try await binaryResolver.resolve(entry: serverEntry)
        } catch {
            // 바이너리 리졸브 실패 시 소스 빌드 폴백
            stderr.write("바이너리를 찾을 수 없습니다. 소스 빌드로 폴백합니다...")
            let sourceResolver = SourceResolver()
            do {
                let binaryPath = try await sourceResolver.build(entry: serverEntry, name: name)
                stderr.write("소스 빌드 완료. 실행 중...")
                let runner = ProcessRunner()
                let exitCode = try runner.run(
                    executableURL: URL(fileURLWithPath: binaryPath),
                    arguments: buildArguments(for: serverEntry)
                )
                throw ExitCode(exitCode)
            } catch let exitError as ExitCode {
                throw exitError
            } catch {
                stderr.writeError("소스 빌드 실패: \(error)")
                throw ExitCode.failure
            }
        }

        let version = resolvedInfo.version
        let downloadURL = resolvedInfo.url

        if let cachedPath = cacheManager.cachedBinaryPath(name: name, version: version) {
            // 캐시 히트 — 즉시 실행
            stderr.write("캐시에서 '\(name)@\(version)' 실행 중...")
            let runner = ProcessRunner()
            let exitCode = try runner.run(
                executableURL: URL(fileURLWithPath: cachedPath),
                arguments: passthroughArguments
            )
            throw ExitCode(exitCode)
        }

        // 다운로드 후 실행
        stderr.write("Downloading '\(name)@\(version)'...")
        do {
            let binaryPath = try await cacheManager.download(
                url: downloadURL,
                name: name,
                version: version,
                executableName: serverEntry.executable
            )
            stderr.write("Running '\(name)'...")
            let runner = ProcessRunner()
            let exitCode = try runner.run(
                executableURL: URL(fileURLWithPath: binaryPath),
                arguments: passthroughArguments
            )
            throw ExitCode(exitCode)
        } catch let exitError as ExitCode {
            throw exitError
        } catch {
            stderr.writeError("실행 실패: \(error)")
            throw ExitCode.failure
        }
    }
}
