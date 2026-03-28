// RegistrySchema.swift
// 레지스트리 JSON Codable 스키마 정의
// RegistryEntry, ServerEntry, PlatformEntry, SourceEntry

import Foundation

/// 레지스트리 최상위 구조
/// {"version": 1, "servers": {"name": ServerEntry}}
nonisolated struct RegistryEntry: Codable, Sendable {
    /// 스키마 버전 (현재 1)
    let version: Int
    /// 서버 이름 → 서버 엔트리 딕셔너리
    let servers: [String: ServerEntry]
}

/// 개별 MCP 서버 엔트리
nonisolated struct ServerEntry: Codable, Sendable {
    /// GitHub 저장소 (owner/repo 형식)
    let repo: String
    /// 서버 설명
    let description: String
    /// 실행 파일 이름 (바이너리 이름)
    let executable: String
    /// MCP 서버 시작에 필요한 추가 인수 (e.g. ["mcp", "serve"])
    let args: [String]?
    /// 플랫폼별 artifact 정보
    let platforms: [String: PlatformEntry]
    /// 소스 빌드 정보 (옵션: 바이너리가 없을 때 소스 폴백)
    let source: SourceEntry?
}

/// 플랫폼별 artifact 정보
/// {"macos-arm64": {"artifact": "name-macos-arm64.tar.gz"}}
nonisolated struct PlatformEntry: Codable, Sendable {
    /// GitHub Releases artifact 파일명
    let artifact: String
}

/// 소스 빌드 정보
nonisolated struct SourceEntry: Codable, Sendable {
    /// 빌드 루트 디렉토리 (저장소 내 상대 경로, e.g. "CLI" or ".")
    let buildPath: String
    /// 빌드 커맨드 (e.g. "swift build -c release")
    let buildCommand: String
    /// 빌드 결과 실행 파일 product 이름
    let product: String
}
