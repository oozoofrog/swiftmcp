// RegistryClient.swift
// GitHub raw URL에서 registry.json fetch + 로컬 캐시 저장/로드
// 캐시 TTL: 1시간 (3600초)

import Foundation

/// 레지스트리 클라이언트 — GitHub raw URL fetch + 로컬 캐싱
nonisolated struct RegistryClient: Sendable {

    /// 레지스트리 원격 URL
    static let registryURL = "https://raw.githubusercontent.com/oozoofrog/swiftmcp/main/registry.json"

    /// 로컬 캐시 디렉토리
    static var cacheDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.swiftmcp/registry"
    }

    /// 캐시 파일 경로
    private var cacheFilePath: String {
        "\(Self.cacheDirectory)/registry.json"
    }

    /// 캐시 TTL: 1시간
    private let cacheTTL: TimeInterval = 60 * 60

    /// 레지스트리를 fetch (캐시 유효 시 네트워크 미호출)
    func fetch() async throws -> RegistryEntry {
        // 캐시 유효성 확인
        if let cached = loadCache(), isCacheValid(cached.modificationDate) {
            return cached.entry
        }
        // 네트워크 fetch 시도
        do {
            return try await fetchFromNetwork()
        } catch {
            // 네트워크 실패 시 만료된 캐시라도 반환 (폴백)
            if let cached = loadCache() {
                return cached.entry
            }
            throw error
        }
    }

    /// 캐시를 무시하고 강제로 네트워크에서 fetch
    func forceFetch() async throws -> RegistryEntry {
        return try await fetchFromNetwork()
    }

    // MARK: - Private

    /// 네트워크에서 레지스트리 JSON fetch
    private func fetchFromNetwork() async throws -> RegistryEntry {
        guard let url = URL(string: Self.registryURL) else {
            throw SwiftMCPError.networkError("잘못된 레지스트리 URL")
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SwiftMCPError.networkError("레지스트리 서버 응답 오류")
        }

        let decoder = JSONDecoder()
        let entry = try decoder.decode(RegistryEntry.self, from: data)

        // 캐시 저장
        saveCache(data: data)

        return entry
    }

    /// 캐시에서 레지스트리 로드
    private func loadCache() -> (entry: RegistryEntry, modificationDate: Date)? {
        let path = cacheFilePath
        let fm = FileManager.default

        guard fm.fileExists(atPath: path),
              let data = fm.contents(atPath: path) else {
            return nil
        }

        // 파일 수정 날짜 확인
        let modDate: Date
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let date = attrs[.modificationDate] as? Date {
            modDate = date
        } else {
            modDate = Date.distantPast
        }

        let decoder = JSONDecoder()
        guard let entry = try? decoder.decode(RegistryEntry.self, from: data) else {
            return nil
        }

        return (entry, modDate)
    }

    /// 캐시 TTL 유효성 검사 (1시간)
    private func isCacheValid(_ modificationDate: Date) -> Bool {
        let age = Date().timeIntervalSince(modificationDate)
        return age < cacheTTL
    }

    /// 레지스트리 JSON 데이터를 캐시 파일에 저장
    private func saveCache(data: Data) {
        let fm = FileManager.default
        let dir = Self.cacheDirectory

        // 캐시 디렉토리 생성
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        fm.createFile(atPath: cacheFilePath, contents: data)
    }
}
