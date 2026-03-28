// BinaryResolver.swift
// GitHub Releases API에서 latest release 조회 + 플랫폼 자동 감지
// arch 명령 기반 arm64/x86_64 선택 → artifact URL 추출

import Foundation

/// GitHub Releases API 응답 모델
nonisolated struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

/// GitHub Release asset 정보
nonisolated struct GitHubAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

/// 바이너리 URL 리졸버 — GitHub Releases API 기반 플랫폼별 artifact URL 추출
nonisolated struct BinaryResolver: Sendable {

    /// 현재 플랫폼 키 (macos-arm64 또는 macos-x86_64)
    static func detectPlatform() -> String? {
        // arch 명령으로 CPU 아키텍처 감지
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        // arch 명령 실행 실패 시 컴파일 타임 감지로 즉시 폴백
        guard (try? process.run()) != nil else {
            #if arch(arm64)
            return "macos-arm64"
            #elseif arch(x86_64)
            return "macos-x86_64"
            #else
            return nil
            #endif
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let arch = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch arch {
        case "arm64":
            return "macos-arm64"
        case "x86_64", "i386":
            return "macos-x86_64"
        default:
            // ProcessInfo 폴백
            #if arch(arm64)
            return "macos-arm64"
            #elseif arch(x86_64)
            return "macos-x86_64"
            #else
            return nil
            #endif
        }
    }

    /// 서버 엔트리에서 플랫폼별 바이너리 URL 추출
    /// - Returns: (다운로드 URL, 버전 태그)
    func resolve(entry: ServerEntry) async throws -> (url: URL, version: String) {
        // 플랫폼 감지
        guard let platform = Self.detectPlatform() else {
            throw SwiftMCPError.unsupportedPlatform("현재 플랫폼을 감지할 수 없습니다.")
        }

        // 플랫폼 artifact 확인
        guard let platformEntry = entry.platforms[platform] else {
            throw SwiftMCPError.unsupportedPlatform("플랫폼 '\(platform)'은 지원되지 않습니다.")
        }

        // GitHub Releases API 호출
        let release = try await fetchLatestRelease(repo: entry.repo)
        let version = release.tagName

        // artifact 이름으로 asset URL 찾기
        guard let asset = release.assets.first(where: { $0.name == platformEntry.artifact }) else {
            throw SwiftMCPError.artifactNotFound(
                "릴리스 \(version)에서 artifact '\(platformEntry.artifact)'를 찾을 수 없습니다."
            )
        }

        guard let downloadURL = URL(string: asset.browserDownloadURL) else {
            throw SwiftMCPError.networkError("잘못된 다운로드 URL: \(asset.browserDownloadURL)")
        }

        return (downloadURL, version)
    }

    // MARK: - Private

    /// GitHub Releases API에서 latest release 정보 fetch
    private func fetchLatestRelease(repo: String) async throws -> GitHubRelease {
        let apiURL = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: apiURL) else {
            throw SwiftMCPError.networkError("잘못된 API URL: \(apiURL)")
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SwiftMCPError.networkError("잘못된 HTTP 응답")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404 {
                throw SwiftMCPError.artifactNotFound("저장소 '\(repo)'에 릴리스가 없습니다.")
            }
            throw SwiftMCPError.networkError("GitHub API 응답 오류: \(httpResponse.statusCode)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(GitHubRelease.self, from: data)
    }
}
