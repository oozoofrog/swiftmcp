// NetworkChecker.swift
// github.com 및 raw.githubusercontent.com 에 HEAD 요청으로 네트워크 연결 확인
// 응답 시간(ms) 측정, 타임아웃 5초

import Foundation

/// 네트워크 연결 상태 체커
nonisolated struct NetworkChecker: DoctorCheck, Sendable {
    let name = "Network"

    /// 확인할 호스트 목록
    private let hosts: [(name: String, urlString: String)] = [
        ("github.com", "https://github.com"),
        ("raw.githubusercontent.com", "https://raw.githubusercontent.com"),
    ]

    func run() async -> [DoctorResult] {
        var results: [DoctorResult] = []

        for host in hosts {
            let result = await checkHost(name: host.name, urlString: host.urlString)
            results.append(result)
        }

        return results
    }

    // MARK: - Private

    /// 특정 호스트에 HEAD 요청하여 연결 상태 확인
    private func checkHost(name: String, urlString: String) async -> DoctorResult {
        guard let url = URL(string: urlString) else {
            return DoctorResult(
                name: self.name,
                status: .fail,
                message: "\(name): 잘못된 URL",
                detail: urlString
            )
        }

        // 타임아웃 5초 설정
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 5.0
        let session = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let startTime = Date()

        do {
            let (_, response) = try await session.data(for: request)

            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

            guard let httpResponse = response as? HTTPURLResponse else {
                return DoctorResult(
                    name: self.name,
                    status: .warning,
                    message: "\(name): HTTP 응답 없음",
                    detail: "\(elapsed)ms"
                )
            }

            // HTTP 4xx/5xx 시 warning
            if httpResponse.statusCode >= 400 {
                return DoctorResult(
                    name: self.name,
                    status: .warning,
                    message: "\(name): HTTP \(httpResponse.statusCode) (\(elapsed)ms)",
                    detail: urlString
                )
            }

            return DoctorResult(
                name: self.name,
                status: .pass,
                message: "\(name) 접근 가능 (\(elapsed)ms)",
                detail: "HTTP \(httpResponse.statusCode)"
            )

        } catch {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

            // 타임아웃 또는 연결 실패 → fail
            return DoctorResult(
                name: self.name,
                status: .fail,
                message: "\(name): 연결 실패 (\(elapsed)ms)",
                detail: error.localizedDescription
            )
        }
    }
}
