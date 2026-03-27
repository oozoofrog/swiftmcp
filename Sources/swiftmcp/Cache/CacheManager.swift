// CacheManager.swift
// ~/.swiftmcp/cache/{name}/{version}/ 경로 관리
// tar.gz 다운로드 후 압축 해제, binary 실행 권한 설정

import Foundation

/// 캐시 관리자 — ~/.swiftmcp/cache/ 디렉토리 관리
nonisolated struct CacheManager: Sendable {

    /// 캐시 루트 디렉토리
    static var cacheRoot: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.swiftmcp/cache"
    }

    /// 특정 패키지·버전의 캐시 디렉토리 경로
    func cacheDir(name: String, version: String) -> String {
        "\(Self.cacheRoot)/\(name)/\(version)"
    }

    /// 캐시에 설치된 바이너리 경로 반환 (없으면 nil)
    func cachedBinaryPath(name: String, version: String) -> String? {
        let dir = cacheDir(name: name, version: version)
        let fm = FileManager.default

        // 디렉토리가 있으면 그 안의 실행 파일 탐색
        guard fm.fileExists(atPath: dir) else { return nil }

        guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { return nil }

        // 실행 권한이 있는 파일 반환
        for item in contents {
            let itemPath = "\(dir)/\(item)"
            if isExecutable(path: itemPath) {
                return itemPath
            }
        }

        return nil
    }

    /// tar.gz 다운로드 후 압축 해제, binary 캐싱
    /// - Returns: 캐시된 binary 경로
    func download(url: URL, name: String, version: String, executableName: String) async throws -> String {
        let fm = FileManager.default
        let cacheDirectory = cacheDir(name: name, version: version)

        // 캐시 디렉토리 생성
        try fm.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)

        // 임시 파일에 다운로드
        let tmpFile = "\(NSTemporaryDirectory())/swiftmcp-\(name)-\(version).tar.gz"

        let (tmpURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SwiftMCPError.downloadFailed("다운로드 실패: HTTP 오류")
        }

        // 임시 파일로 이동
        if fm.fileExists(atPath: tmpFile) {
            try fm.removeItem(atPath: tmpFile)
        }
        try fm.moveItem(at: tmpURL, to: URL(fileURLWithPath: tmpFile))

        // tar -xzf 압축 해제
        try extractTarGz(archivePath: tmpFile, destinationDir: cacheDirectory)

        // 임시 파일 정리
        try? fm.removeItem(atPath: tmpFile)

        // 실행 파일 경로 탐색
        let binaryPath = "\(cacheDirectory)/\(executableName)"
        if fm.fileExists(atPath: binaryPath) {
            // 실행 권한 설정 (chmod +x)
            try setExecutablePermission(path: binaryPath)
            return binaryPath
        }

        // 이름이 다를 수 있으므로 디렉토리 스캔
        if let contents = try? fm.contentsOfDirectory(atPath: cacheDirectory),
           let found = contents.first {
            let foundPath = "\(cacheDirectory)/\(found)"
            try setExecutablePermission(path: foundPath)
            return foundPath
        }

        throw SwiftMCPError.extractionFailed("압축 해제 후 실행 파일을 찾을 수 없습니다.")
    }

    /// 설치된 패키지 목록 반환
    func listInstalledPackages() -> [InstalledPackage] {
        let fm = FileManager.default
        let root = Self.cacheRoot

        guard let packageNames = try? fm.contentsOfDirectory(atPath: root) else {
            return []
        }

        var result: [InstalledPackage] = []

        for packageName in packageNames.sorted() {
            let packageDir = "\(root)/\(packageName)"
            guard let versions = try? fm.contentsOfDirectory(atPath: packageDir) else {
                continue
            }

            for version in versions.sorted().reversed() {
                let versionDir = "\(packageDir)/\(version)"
                if let binaryPath = cachedBinaryPath(name: packageName, version: version) {
                    result.append(InstalledPackage(
                        name: packageName,
                        version: version,
                        binaryPath: binaryPath
                    ))
                    break // 최신 버전만 표시
                }
                _ = versionDir // 사용됨 표시
            }
        }

        return result
    }

    /// 특정 패키지 캐시 삭제
    func clean(name: String) throws {
        let packageDir = "\(Self.cacheRoot)/\(name)"
        let fm = FileManager.default

        guard fm.fileExists(atPath: packageDir) else {
            throw SwiftMCPError.packageNotFound("'\(name)' 캐시를 찾을 수 없습니다.")
        }

        try fm.removeItem(atPath: packageDir)
    }

    /// 전체 캐시 삭제
    func cleanAll() throws {
        let fm = FileManager.default
        let root = Self.cacheRoot

        guard fm.fileExists(atPath: root) else { return }

        let contents = try fm.contentsOfDirectory(atPath: root)
        for item in contents {
            try fm.removeItem(atPath: "\(root)/\(item)")
        }
    }

    // MARK: - Private

    /// tar -xzf로 압축 해제 (Foundation Process 사용)
    private func extractTarGz(archivePath: String, destinationDir: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archivePath, "-C", destinationDir]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SwiftMCPError.extractionFailed("tar 압축 해제 실패 (exit code: \(process.terminationStatus))")
        }
    }

    /// 파일에 실행 권한 설정 (chmod +x, posixPermissions 0o755)
    private func setExecutablePermission(path: String) throws {
        let fm = FileManager.default
        try fm.setAttributes(
            [.posixPermissions: 0o755 as NSNumber],
            ofItemAtPath: path
        )
    }

    /// 파일이 실행 가능한지 확인
    private func isExecutable(path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }

        // 디렉토리가 아닌 경우
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }

        return fm.isExecutableFile(atPath: path)
    }
}
