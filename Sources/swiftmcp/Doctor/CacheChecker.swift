// CacheChecker.swift
// ~/.swiftmcp/ 디렉토리 존재 여부, 캐시 패키지 수, 총 디스크 사용량(MB) 확인
// FileManager 기반 디렉토리 순회

import Foundation

/// 캐시 상태 체커
nonisolated struct CacheChecker: DoctorCheck, Sendable {
    let name = "Cache"

    func run() async -> [DoctorResult] {
        let cacheManager = CacheManager()
        let cacheRoot = cacheManager.cacheRoot
        let fm = FileManager.default

        // 캐시 디렉토리 없으면 warning (미사용)
        guard fm.fileExists(atPath: cacheRoot) else {
            return [DoctorResult(
                name: name,
                status: .warning,
                message: "캐시 디렉토리가 없습니다 (아직 미사용)",
                detail: cacheRoot
            )]
        }

        // 패키지 수 계산 (캐시 루트 직속 디렉토리 = 패키지 이름)
        let packages = cacheManager.listInstalledPackages()
        let packageCount = packages.count

        // 총 디스크 사용량 계산
        let totalSizeBytes = calculateDirectorySize(path: cacheRoot, fileManager: fm)
        let totalSizeMB = Double(totalSizeBytes) / 1_000_000.0

        let sizeStr = String(format: "%.1f MB", totalSizeMB)

        return [DoctorResult(
            name: name,
            status: .pass,
            message: "\(packageCount)개 패키지, \(sizeStr)",
            detail: cacheRoot
        )]
    }

    // MARK: - Private

    /// 디렉토리 전체 크기 계산 (바이트)
    private func calculateDirectorySize(path: String, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  resourceValues.isRegularFile == true,
                  let fileSize = resourceValues.fileSize else {
                continue
            }
            totalSize += Int64(fileSize)
        }

        return totalSize
    }
}
