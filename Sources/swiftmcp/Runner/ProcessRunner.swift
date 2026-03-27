// ProcessRunner.swift
// Process(executableURL:) 기반 stdio passthrough 실행
// MCP 서버 ↔ Claude 직접 통신을 위한 stdin/stdout/stderr 상속

import Foundation

/// 프로세스 실행기 — stdio passthrough 방식으로 하위 프로세스 실행
nonisolated struct ProcessRunner: Sendable {

    /// 하위 프로세스를 stdio passthrough 방식으로 실행
    /// - Parameters:
    ///   - executableURL: 실행 파일 URL
    ///   - arguments: 전달할 인수
    /// - Returns: terminationStatus (0 = 성공)
    func run(executableURL: URL, arguments: [String] = []) throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        // stdio passthrough — MCP 통신용으로 stdin/stdout/stderr 상속
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        return process.terminationStatus
    }
}
