// SourceResolver.swift
// 소스 폴백 빌드: git clone → swift build -c release → 캐시에 복사
// Swift 툴체인이 있을 때 레지스트리 등록 전 패키지도 실행 가능

import Foundation

/// 소스 빌드 리졸버 — 바이너리 릴리스가 없을 때 소스에서 빌드
nonisolated struct SourceResolver: Sendable {

    /// 소스에서 빌드하여 캐시에 저장
    /// - Returns: 캐시된 binary 경로
    func build(entry: ServerEntry, name: String) async throws -> String {
        guard let source = entry.source else {
            throw MCPSWXError.sourceBuildFailed("'\(name)'에 source 빌드 정보가 없습니다.")
        }

        // 임시 디렉토리에 git clone
        let tmpDir = "\(NSTemporaryDirectory())mcpswx-src-\(name)-\(UUID().uuidString)"
        let fm = FileManager.default

        defer {
            // 임시 디렉토리 정리
            try? fm.removeItem(atPath: tmpDir)
        }

        // git clone
        let repoURL = "https://github.com/\(entry.repo).git"
        try await runProcess(
            executable: "/usr/bin/git",
            arguments: ["clone", "--depth", "1", repoURL, tmpDir]
        )

        // 빌드 경로 결정
        let buildDir: String
        if source.buildPath == "." {
            buildDir = tmpDir
        } else {
            buildDir = "\(tmpDir)/\(source.buildPath)"
        }

        // buildCommand 파싱: nil이면 기본값 "swift build -c release" 사용
        let rawCommand = source.buildCommand.isEmpty
            ? "swift build -c release"
            : source.buildCommand
        // 공백 기준으로 split하여 인수 배열 생성
        var buildArgs = rawCommand.split(separator: " ").map(String.init)
        guard let buildExecutableName = buildArgs.first else {
            throw MCPSWXError.sourceBuildFailed("buildCommand 파싱 실패: '\(rawCommand)'")
        }
        buildArgs.removeFirst()

        // 실행 파일 경로 결정: swift 또는 절대 경로
        let buildExecutable: String
        if buildExecutableName.hasPrefix("/") {
            buildExecutable = buildExecutableName
        } else {
            buildExecutable = "/usr/bin/\(buildExecutableName)"
        }

        // --product 인수가 buildCommand에 없으면 자동 추가
        if !buildArgs.contains("--product") {
            buildArgs += ["--product", source.product]
        }

        try await runProcess(
            executable: buildExecutable,
            arguments: buildArgs,
            workingDirectory: buildDir
        )

        // 빌드된 바이너리 경로
        let builtBinaryPath = "\(buildDir)/.build/release/\(source.product)"
        guard fm.fileExists(atPath: builtBinaryPath) else {
            throw MCPSWXError.sourceBuildFailed(
                "빌드 완료 후 '\(source.product)' 바이너리를 찾을 수 없습니다."
            )
        }

        // 캐시에 복사 (버전은 "source-build"로 표시)
        let cacheManager = CacheManager()
        let version = "source-build"
        let cacheDirectory = cacheManager.cacheDir(name: name, version: version)

        try fm.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)

        let cachedPath = "\(cacheDirectory)/\(source.product)"
        if fm.fileExists(atPath: cachedPath) {
            try fm.removeItem(atPath: cachedPath)
        }
        try fm.copyItem(atPath: builtBinaryPath, toPath: cachedPath)

        // 실행 권한 설정
        try fm.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: cachedPath)

        return cachedPath
    }

    // MARK: - Private

    /// 외부 프로세스를 비동기 실행
    private func runProcess(
        executable: String,
        arguments: [String],
        workingDirectory: String? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                if let workDir = workingDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: workDir)
                }

                // stderr는 표준 에러로 전달 (진행 상황 표시용)
                process.standardOutput = Pipe()
                process.standardError = FileHandle.standardError

                process.terminationHandler = { p in
                    if p.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: MCPSWXError.sourceBuildFailed(
                            "\(executable) 실패 (exit code: \(p.terminationStatus))"
                        ))
                    }
                }

                try process.run()
            } catch {
                continuation.resume(throwing: MCPSWXError.sourceBuildFailed(
                    "프로세스 실행 실패: \(error)"
                ))
            }
        }
    }
}
