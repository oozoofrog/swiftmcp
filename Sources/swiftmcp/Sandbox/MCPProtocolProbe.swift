// MCPProtocolProbe.swift
// MCP 서버 바이너리를 Pipe 방식으로 실행하여 JSON-RPC 2.0 프로토콜 검증
// 시퀀스: initialize → initialized notification → tools/list → tools/call

import Foundation

/// MCP 프로토콜 검증 결과
struct MCPProbeResult: Sendable {
    /// initialize 응답에서 파악한 서버 정보
    let serverInfo: String
    /// 등록된 tool 목록
    let tools: [String]
    /// tools/call 결과 (성공 여부)
    let toolCallSuccess: Bool
    /// tools/call에 사용한 tool 이름
    let calledTool: String?
}

/// MCP 프로토콜 에러
enum MCPProbeError: Error, LocalizedError, Sendable {
    case processStartFailed(String)
    case initializeTimeout
    case initializeFailed(String)
    case toolsListFailed(String)
    case timeout(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .processStartFailed(let msg): return "프로세스 시작 실패: \(msg)"
        case .initializeTimeout: return "initialize 응답 타임아웃"
        case .initializeFailed(let msg): return "initialize 실패: \(msg)"
        case .toolsListFailed(let msg): return "tools/list 실패: \(msg)"
        case .timeout(let msg): return "타임아웃: \(msg)"
        case .invalidResponse(let msg): return "잘못된 응답: \(msg)"
        }
    }
}

/// MCP JSON-RPC 프로토콜 검증기 (Pipe 기반)
nonisolated struct MCPProtocolProbe: Sendable {
    /// 응답 대기 최대 시간 (초)
    let timeout: TimeInterval
    /// tools/call 테스트에 사용할 tool 이름 (nil이면 첫 번째 tool)
    let preferredTool: String?

    init(timeout: TimeInterval = 30, preferredTool: String? = nil) {
        self.timeout = timeout
        self.preferredTool = preferredTool
    }

    /// MCP 서버 바이너리를 Pipe 방식으로 실행하여 4단계 JSON-RPC 시퀀스 실행
    /// - Parameters:
    ///   - binaryPath: 실행 파일 경로
    ///   - args: MCP 서버 시작에 필요한 추가 인수 (e.g. ["mcp", "serve"])
    func probe(binaryPath: String, args: [String] = []) async throws -> MCPProbeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args

        // stdin/stdout을 Pipe로 연결
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 프로세스 시작
        do {
            try process.run()
        } catch {
            throw MCPProbeError.processStartFailed(error.localizedDescription)
        }

        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let stdinHandle = stdinPipe.fileHandleForWriting
        let stdoutHandle = stdoutPipe.fileHandleForReading

        // MARK: - 단계 1: initialize 요청

        // JSON-RPC initialize 요청 직접 작성
        let initJSON = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"swiftmcp-test","version":"1.0.0"}}}
        """
        writeJSONLine(initJSON, to: stdinHandle)

        // initialize 응답 읽기 (타임아웃 적용)
        guard let initData = try await readResponseData(from: stdoutHandle, label: "initialize") else {
            throw MCPProbeError.initializeFailed("응답 없음 (타임아웃)")
        }

        guard let initResponse = try? JSONSerialization.jsonObject(with: initData) as? [String: Any] else {
            throw MCPProbeError.initializeFailed("JSON 파싱 실패")
        }

        guard let _ = initResponse["result"] else {
            let errMsg = (initResponse["error"] as? [String: Any])?["message"] as? String ?? "응답 없음"
            throw MCPProbeError.initializeFailed(errMsg)
        }

        // serverInfo 파싱
        let result = initResponse["result"] as? [String: Any] ?? [:]
        let serverInfoObj = result["serverInfo"] as? [String: Any] ?? [:]
        let serverName = serverInfoObj["name"] as? String ?? "unknown"
        let serverVersion = serverInfoObj["version"] as? String ?? "unknown"
        let serverInfo = "\(serverName) v\(serverVersion)"

        // MARK: - 단계 2: initialized notification 전송

        let initializedJSON = """
        {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
        """
        writeJSONLine(initializedJSON, to: stdinHandle)

        // MARK: - 단계 3: tools/list 요청

        let toolsListJSON = """
        {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
        """
        writeJSONLine(toolsListJSON, to: stdinHandle)

        guard let toolsData = try await readResponseData(from: stdoutHandle, label: "tools/list") else {
            throw MCPProbeError.toolsListFailed("응답 없음 (타임아웃)")
        }

        guard let toolsListResponse = try? JSONSerialization.jsonObject(with: toolsData) as? [String: Any],
              let toolsResult = toolsListResponse["result"] as? [String: Any] else {
            throw MCPProbeError.toolsListFailed("JSON 파싱 실패")
        }

        let toolsArray = toolsResult["tools"] as? [[String: Any]] ?? []
        let toolNames = toolsArray.compactMap { $0["name"] as? String }

        // MARK: - 단계 4: tools/call 요청

        var toolCallSuccess = false
        var calledTool: String? = nil

        // 호출할 tool 선택
        let targetTool = preferredTool.flatMap { name in toolNames.first { $0 == name } }
                         ?? toolNames.first

        if let toolName = targetTool {
            calledTool = toolName

            // JSON 문자열 이스케이핑
            let escapedName = toolName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")

            let toolCallJSON = """
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"\(escapedName)","arguments":{}}}
            """
            writeJSONLine(toolCallJSON, to: stdinHandle)

            if let callData = try? await readResponseData(from: stdoutHandle, label: "tools/call"),
               let callResponse = try? JSONSerialization.jsonObject(with: callData) as? [String: Any] {
                // 결과 또는 에러 모두 응답이 왔으면 통신 성공으로 간주
                toolCallSuccess = callResponse["result"] != nil || callResponse["error"] != nil
            }
        }

        // stdin 닫기 (프로세스 종료 신호)
        stdinHandle.closeFile()

        return MCPProbeResult(
            serverInfo: serverInfo,
            tools: toolNames,
            toolCallSuccess: toolCallSuccess,
            calledTool: calledTool
        )
    }

    // MARK: - 헬퍼

    /// JSON 문자열을 줄바꿈 구분 방식으로 Pipe에 쓰기
    private func writeJSONLine(_ json: String, to handle: FileHandle) {
        if let data = (json + "\n").data(using: .utf8) {
            handle.write(data)
        }
    }

    /// stdout Pipe에서 JSON 응답 Data 읽기 (타임아웃 적용)
    private func readResponseData(from handle: FileHandle, label: String) async throws -> Data? {
        let intervalNs: UInt64 = 100_000_000 // 100ms
        let maxAttempts = Int(timeout / 0.1) // 타임아웃 / 100ms
        var buffer = Data()

        for _ in 0..<maxAttempts {
            try Task.checkCancellation()

            let chunk = handle.availableData
            if !chunk.isEmpty {
                buffer.append(chunk)

                // 줄바꿈 기반 JSON 파싱 시도
                if let newlineRange = buffer.range(of: Data([0x0a])) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                    if (try? JSONSerialization.jsonObject(with: lineData)) != nil {
                        return lineData
                    }
                }

                // 전체 버퍼로 파싱 시도 (줄바꿈 없이 응답하는 서버 대응)
                if (try? JSONSerialization.jsonObject(with: buffer)) != nil {
                    return buffer
                }
            }

            // 100ms 대기
            try await Task.sleep(nanoseconds: intervalNs)
        }

        return nil
    }
}
