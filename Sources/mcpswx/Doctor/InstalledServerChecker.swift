// InstalledServerChecker.swift
// CacheManager.listInstalledPackages()로 설치된 서버 목록 조회 후
// 각 바이너리의 실행 가능 여부 확인

import Foundation

/// 설치된 MCP 서버 상태 체커
nonisolated struct InstalledServerChecker: DoctorCheck, Sendable {
    let name = "Installed Servers"

    func run() async -> [DoctorResult] {
        let cacheManager = CacheManager()
        let packages = cacheManager.listInstalledPackages()

        // 설치된 패키지가 없으면 warning
        if packages.isEmpty {
            return [DoctorResult(
                name: name,
                status: .warning,
                message: "설치된 MCP 서버 없음",
                detail: "mcpswx install <name> 으로 설치하세요."
            )]
        }

        // 각 패키지별 바이너리 상태 확인
        var results: [DoctorResult] = []

        for package in packages {
            let result = checkPackage(package)
            results.append(result)
        }

        return results
    }

    // MARK: - Private

    /// 개별 패키지의 바이너리 상태 확인
    private func checkPackage(_ package: InstalledPackage) -> DoctorResult {
        let fm = FileManager.default
        let binaryPath = package.binaryPath
        let label = "\(package.name)@\(package.version)"

        // 바이너리 파일 존재 여부 확인
        guard fm.fileExists(atPath: binaryPath) else {
            return DoctorResult(
                name: name,
                status: .fail,
                message: "\(label): 바이너리 없음",
                detail: binaryPath
            )
        }

        // 실행 권한 확인 (FileManager.isExecutableFile)
        guard fm.isExecutableFile(atPath: binaryPath) else {
            return DoctorResult(
                name: name,
                status: .warning,
                message: "\(label): 실행 권한 없음",
                detail: binaryPath
            )
        }

        return DoctorResult(
            name: name,
            status: .pass,
            message: "\(label): 정상 (실행 가능)",
            detail: binaryPath
        )
    }
}
