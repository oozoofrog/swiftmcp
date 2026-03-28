// RegistryChecker.swift
// RegistryClient.forceFetch()로 레지스트리 접근성 확인
// 등록된 서버 수 반환, 네트워크/파싱 오류 구분하여 fail/warning 반환

import Foundation

/// 레지스트리 접근성 체커
nonisolated struct RegistryChecker: DoctorCheck, Sendable {
    let name = "Registry"

    func run() async -> [DoctorResult] {
        let client = RegistryClient()

        do {
            // 캐시 TTL 무시하고 강제 네트워크 호출로 실제 접근성 검증
            let registry = try await client.forceFetch()
            let serverCount = registry.servers.count

            return [DoctorResult(
                name: name,
                status: .pass,
                message: "접근 가능 (\(serverCount)개 서버 등록됨)",
                detail: RegistryClient.registryURL
            )]

        } catch let error as SwiftMCPError {
            switch error {
            case .networkError(let msg):
                // 네트워크 실패 → fail
                return [DoctorResult(
                    name: name,
                    status: .fail,
                    message: "레지스트리 접근 실패: \(msg)",
                    detail: RegistryClient.registryURL
                )]
            case .invalidJSON(let msg):
                // JSON 파싱 실패 → warning
                return [DoctorResult(
                    name: name,
                    status: .warning,
                    message: "레지스트리 파싱 실패: \(msg)",
                    detail: RegistryClient.registryURL
                )]
            default:
                return [DoctorResult(
                    name: name,
                    status: .fail,
                    message: "레지스트리 오류: \(error.localizedDescription)",
                    detail: RegistryClient.registryURL
                )]
            }
        } catch {
            // DecodingError 등 기타 오류는 warning (파싱 오류로 분류)
            if error is DecodingError {
                return [DoctorResult(
                    name: name,
                    status: .warning,
                    message: "레지스트리 JSON 파싱 오류",
                    detail: error.localizedDescription
                )]
            }

            return [DoctorResult(
                name: name,
                status: .fail,
                message: "레지스트리 접근 실패",
                detail: error.localizedDescription
            )]
        }
    }
}
