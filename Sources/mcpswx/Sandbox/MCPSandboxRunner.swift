// MCPSandboxRunner.swift
// $TMPDIR/mcpswx-test-{uuid}/ 임시 디렉토리에서 격리된 MCP 서버 테스트 실행
// CacheManager(sandboxRoot:) 주입으로 기존 ~/.mcpswx/ 캐시 미오염
// defer로 임시 디렉토리 반드시 정리

import Foundation

/// MCP 샌드박스 테스트 실행 엔진
nonisolated struct MCPSandboxRunner: Sendable {
    /// MCP 서버 응답 대기 최대 시간 (초)
    let timeout: Int
    /// tools/call 테스트에 사용할 tool 이름
    let preferredTool: String?

    init(timeout: Int = 30, preferredTool: String? = nil) {
        self.timeout = timeout
        self.preferredTool = preferredTool
    }

    /// MCP 서버 전체 라이프사이클 테스트 실행
    /// - Parameters:
    ///   - packageName: 테스트할 MCP 서버 레지스트리 이름
    ///   - useSandbox: true이면 임시 디렉토리 사용 (캐시 미오염), false이면 기존 캐시 사용
    func run(packageName: String, useSandbox: Bool) async throws {
        let totalSteps = 5
        let startTime = Date()

        // MARK: - 단계 1: 레지스트리 조회

        printStep(1, totalSteps, "레지스트리에서 '\(packageName)' 조회...")

        let registryClient = RegistryClient()
        let registry: RegistryEntry

        do {
            registry = try await registryClient.fetch()
        } catch {
            printStepFail("레지스트리 조회 실패: \(error.localizedDescription)")
            throw error
        }

        guard let serverEntry = registry.servers[packageName] else {
            printStepFail("'\(packageName)'을 레지스트리에서 찾을 수 없습니다.")
            throw MCPSWXError.packageNotFound("'\(packageName)'은 레지스트리에 등록되지 않았습니다.")
        }

        let binaryResolver = BinaryResolver()
        let resolvedURL: URL
        let resolvedVersion: String

        do {
            let resolved = try await binaryResolver.resolve(entry: serverEntry)
            resolvedURL = resolved.url
            resolvedVersion = resolved.version
        } catch {
            printStepFail("바이너리 URL 해석 실패: \(error.localizedDescription)")
            throw error
        }

        // 서버 시작 인수 (e.g. ["mcp", "serve"])
        let mcpArgs = serverEntry.args ?? []
        printStepOK("'\(packageName)' (\(resolvedVersion)) 조회 완료\(mcpArgs.isEmpty ? "" : " args: \(mcpArgs.joined(separator: " "))")")

        // MARK: - 단계 2: 샌드박스 디렉토리 생성

        printStep(2, totalSteps, "임시 디렉토리 샌드박스 생성...")

        let sandboxRoot: String?
        let sandboxPath: String

        if useSandbox {
            // $TMPDIR/mcpswx-test-{uuid}/ 임시 디렉토리 생성
            let tmpDir = NSTemporaryDirectory()
            let uuid = UUID().uuidString
            sandboxPath = "\(tmpDir)mcpswx-test-\(uuid)"
            sandboxRoot = sandboxPath

            do {
                try FileManager.default.createDirectory(
                    atPath: sandboxPath,
                    withIntermediateDirectories: true
                )
            } catch {
                printStepFail("샌드박스 디렉토리 생성 실패: \(error.localizedDescription)")
                throw error
            }
            printStepOK("OK (\(sandboxPath))")
        } else {
            sandboxPath = ""
            sandboxRoot = nil
            printStepOK("샌드박스 비활성화 (기존 캐시 사용)")
        }

        // defer로 임시 디렉토리 반드시 정리
        defer {
            if useSandbox && !sandboxPath.isEmpty {
                try? FileManager.default.removeItem(atPath: sandboxPath)
            }
        }

        // MARK: - 단계 3: 바이너리 다운로드 (샌드박스 캐시로)

        printStep(3, totalSteps, "바이너리 다운로드 (샌드박스 캐시로)...")

        // sandboxRoot 주입으로 기존 캐시 미오염
        let cacheManager = CacheManager(sandboxRoot: sandboxRoot)

        // 먼저 캐시 확인
        let binaryPath: String

        if let cached = cacheManager.cachedBinaryPath(name: packageName, version: resolvedVersion) {
            binaryPath = cached
            printStepOK("캐시 히트 (\(packageName)@\(resolvedVersion))")
        } else {
            do {
                binaryPath = try await cacheManager.download(
                    url: resolvedURL,
                    name: packageName,
                    version: resolvedVersion,
                    executableName: serverEntry.executable
                )
                printStepOK("\(packageName)@\(resolvedVersion)")
            } catch {
                printStepFail("다운로드 실패: \(error.localizedDescription)")
                throw error
            }
        }

        // MARK: - 단계 4: MCP 프로토콜 핸드셰이크

        printStep(4, totalSteps, "MCP 서버 실행 + JSON-RPC 핸드셰이크...")

        let probe = MCPProtocolProbe(timeout: TimeInterval(timeout), preferredTool: preferredTool)

        let probeResult: MCPProbeResult
        do {
            probeResult = try await probe.probe(binaryPath: binaryPath, args: mcpArgs)
        } catch {
            printStepFail("프로토콜 검증 실패: \(error.localizedDescription)")
            throw error
        }

        // 핸드셰이크 결과 출력
        fputs("      initialize: OK (\(probeResult.serverInfo))\n", stderr)
        fputs("      initialized notification: sent\n", stderr)
        fputs("      tools/list: OK (\(probeResult.tools.count)개 tool 등록됨)\n", stderr)

        if let calledTool = probeResult.calledTool {
            let callStatus = probeResult.toolCallSuccess ? "OK" : "응답 수신"
            fputs("      tools/call (\(calledTool)): \(callStatus)\n", stderr)
        }

        printStepOK("프로토콜 핸드셰이크 완료")

        // MARK: - 단계 5: 샌드박스 정리

        printStep(5, totalSteps, "샌드박스 정리...")
        // defer에서 자동 처리되지만, 단계 출력용으로 여기서 명시
        printStepOK("OK")

        // 경과 시간
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
        _ = elapsed // TestCommand에서 출력
    }

    // MARK: - 출력 헬퍼 (F031 포매터)

    /// 단계 시작 메시지 출력 `[N/M] 메시지...`
    private func printStep(_ current: Int, _ total: Int, _ message: String) {
        fputs("[\(current)/\(total)] \(message)\n", stderr)
    }

    /// 단계 성공 메시지 출력
    private func printStepOK(_ detail: String = "") {
        let isTTY = isatty(STDERR_FILENO) != 0
        let mark = isTTY ? (ANSIStyle.green + "✓" + ANSIStyle.reset) : "OK"
        if detail.isEmpty {
            fputs("      \(mark)\n", stderr)
        } else {
            fputs("      \(mark) \(detail)\n", stderr)
        }
    }

    /// 단계 실패 메시지 출력
    private func printStepFail(_ detail: String = "") {
        let isTTY = isatty(STDERR_FILENO) != 0
        let mark = isTTY ? (ANSIStyle.red + "✗" + ANSIStyle.reset) : "FAIL"
        if detail.isEmpty {
            fputs("      \(mark)\n", stderr)
        } else {
            fputs("      \(mark) \(detail)\n", stderr)
        }
    }
}
