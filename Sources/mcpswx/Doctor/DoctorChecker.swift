// DoctorChecker.swift
// 진단 결과 모델 및 DoctorCheck 프로토콜 정의
// 각 체커는 DoctorCheck 프로토콜을 구현하는 nonisolated struct

import Foundation

// MARK: - 진단 상태

/// 진단 항목의 상태
enum CheckStatus: String, Sendable, Codable {
    /// 정상
    case pass
    /// 실패
    case fail
    /// 경고 (동작하지만 주의 필요)
    case warning
}

// MARK: - 진단 결과

/// 개별 진단 항목의 결과
struct DoctorResult: Sendable, Codable {
    /// 체커 이름 (예: "Swift Toolchain")
    let name: String
    /// 진단 상태
    let status: CheckStatus
    /// 상세 메시지
    let message: String
    /// 추가 상세 정보 (선택)
    let detail: String?

    init(name: String, status: CheckStatus, message: String, detail: String? = nil) {
        self.name = name
        self.status = status
        self.message = message
        self.detail = detail
    }
}

// MARK: - DoctorCheck 프로토콜

/// 진단 체커 프로토콜 — 각 체커는 이 프로토콜을 구현
protocol DoctorCheck: Sendable {
    /// 체커 이름
    var name: String { get }
    /// 진단 실행 — 하나 이상의 DoctorResult 반환
    func run() async -> [DoctorResult]
}

// MARK: - 체커 구현 (nonisolated struct 선언 위치 표시)
// SwiftToolchainChecker.swift — swift --version 실행 및 버전 파싱
// NetworkChecker.swift       — github.com, raw.githubusercontent.com 연결 확인
// CacheChecker.swift         — ~/.mcpswx/ 캐시 상태 확인
// InstalledServerChecker.swift — 설치된 MCP 서버 바이너리 상태 확인
// RegistryChecker.swift      — 레지스트리 접근성 및 서버 수 확인
