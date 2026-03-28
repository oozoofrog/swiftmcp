// SwiftToolchainChecker.swift
// `swift --version` 실행 후 버전 파싱
// PATH 환경 변수 기반으로 swift 바이너리 탐색

import Foundation

/// Swift 툴체인 상태 체커
nonisolated struct SwiftToolchainChecker: DoctorCheck, Sendable {
    let name = "Swift Toolchain"

    func run() async -> [DoctorResult] {
        // swift 바이너리 경로 탐색
        guard let swiftPath = findSwiftBinary() else {
            return [DoctorResult(
                name: name,
                status: .fail,
                message: "Swift 바이너리를 찾을 수 없습니다.",
                detail: "PATH 환경 변수를 확인하거나 Xcode를 설치하세요."
            )]
        }

        // `swift --version` 실행
        let process = Process()
        process.executableURL = URL(fileURLWithPath: swiftPath)
        process.arguments = ["--version"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [DoctorResult(
                name: name,
                status: .fail,
                message: "Swift 실행 실패: \(error.localizedDescription)",
                detail: swiftPath
            )]
        }

        // 출력 파싱 (stdout 또는 stderr에서 버전 읽기)
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let rawOutput = String(data: outputData + errorData, encoding: .utf8) ?? ""

        // 버전 문자열 파싱 (예: "swift-6.2-RELEASE", "Apple Swift version 6.0.3")
        if let version = parseVersion(from: rawOutput) {
            return [DoctorResult(
                name: name,
                status: .pass,
                message: "\(version) (\(swiftPath))",
                detail: rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )]
        } else {
            return [DoctorResult(
                name: name,
                status: .warning,
                message: "Swift는 설치되어 있지만 버전을 파싱할 수 없습니다.",
                detail: rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )]
        }
    }

    // MARK: - Private

    /// PATH 기반으로 swift 바이너리 탐색
    private func findSwiftBinary() -> String? {
        // 일반적인 경로 목록
        let candidates = [
            "/usr/bin/swift",
            "/usr/local/bin/swift",
        ]

        let fm = FileManager.default

        // 고정 경로에서 먼저 탐색
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }

        // PATH 환경 변수에서 탐색
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            let pathDirs = pathEnv.split(separator: ":").map(String.init)
            for dir in pathDirs {
                let fullPath = "\(dir)/swift"
                if fm.isExecutableFile(atPath: fullPath) {
                    return fullPath
                }
            }
        }

        return nil
    }

    /// `swift --version` 출력에서 버전 문자열 파싱
    private func parseVersion(from output: String) -> String? {
        // 패턴 1: "swift-6.2-RELEASE" 형식
        if let range = output.range(of: #"swift-[\d]+\.[\d]+[\w\.-]*"#, options: .regularExpression) {
            return String(output[range])
        }

        // 패턴 2: "Apple Swift version X.Y.Z" 형식
        if let range = output.range(of: #"Apple Swift version [\d]+\.[\d]+[\d.]*"#, options: .regularExpression) {
            return String(output[range])
        }

        // 패턴 3: "Swift version X.Y" 형식
        if let range = output.range(of: #"Swift version [\d]+\.[\d]+"#, options: .regularExpression) {
            return String(output[range])
        }

        return nil
    }
}
