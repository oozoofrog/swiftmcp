// MCPSWXError.swift
// 에러 처리 및 진단 메시지
// 사람이 읽기 좋은 에러 메시지 + stderr 출력

import Foundation

/// mcpswx 에러 타입
enum MCPSWXError: Error, LocalizedError, Sendable {
    /// 네트워크 오류 (URLSession 실패, HTTP 오류)
    case networkError(String)
    /// 레지스트리에 등록되지 않은 패키지
    case packageNotFound(String)
    /// 현재 플랫폼이 지원되지 않음
    case unsupportedPlatform(String)
    /// 다운로드 실패
    case downloadFailed(String)
    /// 압축 해제 실패
    case extractionFailed(String)
    /// 소스 빌드 실패
    case sourceBuildFailed(String)
    /// artifact를 찾을 수 없음
    case artifactNotFound(String)
    /// 잘못된 JSON 형식
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let msg):
            return "네트워크 오류: \(msg)"
        case .packageNotFound(let msg):
            return "패키지를 찾을 수 없습니다: \(msg)"
        case .unsupportedPlatform(let msg):
            return "지원되지 않는 플랫폼: \(msg)"
        case .downloadFailed(let msg):
            return "다운로드 실패: \(msg)"
        case .extractionFailed(let msg):
            return "압축 해제 실패: \(msg)"
        case .sourceBuildFailed(let msg):
            return "소스 빌드 실패: \(msg)"
        case .artifactNotFound(let msg):
            return "artifact를 찾을 수 없습니다: \(msg)"
        case .invalidJSON(let msg):
            return "잘못된 JSON: \(msg)"
        }
    }
}

/// stderr에 메시지를 출력하는 헬퍼
/// MCP 통신용 stdout을 clean 유지하기 위해 모든 진행 상황/에러는 stderr 사용
nonisolated struct StderrWriter: Sendable {
    private let isTTY: Bool

    init() {
        self.isTTY = isatty(STDERR_FILENO) != 0
    }

    /// 일반 메시지 출력 (stderr)
    func write(_ message: String) {
        if isTTY {
            fputs(ANSIStyle.dim + "mcpswx: " + ANSIStyle.reset + message + "\n", stderr)
        } else {
            fputs("mcpswx: " + message + "\n", stderr)
        }
    }

    /// 에러 메시지 출력 (stderr, 빨간색)
    func writeError(_ message: String) {
        if isTTY {
            fputs(ANSIStyle.red + "mcpswx: error: " + ANSIStyle.reset + message + "\n", stderr)
        } else {
            fputs("mcpswx: error: " + message + "\n", stderr)
        }
    }

    /// 성공 메시지 출력 (stderr, 초록색)
    func writeSuccess(_ message: String) {
        if isTTY {
            fputs(ANSIStyle.green + "mcpswx: " + ANSIStyle.reset + message + "\n", stderr)
        } else {
            fputs("mcpswx: " + message + "\n", stderr)
        }
    }

    /// 경고 메시지 출력 (stderr, 노란색)
    func writeWarning(_ message: String) {
        if isTTY {
            fputs(ANSIStyle.yellow + "mcpswx: warning: " + ANSIStyle.reset + message + "\n", stderr)
        } else {
            fputs("mcpswx: warning: " + message + "\n", stderr)
        }
    }
}
