// PackageTemplate.swift
// 생성 프로젝트의 Package.swift 템플릿

import Foundation

/// 프로젝트 템플릿 생성기
nonisolated struct ProjectTemplates: Sendable {
    let projectName: String
    let projectDescription: String

    /// Package.swift 템플릿
    func packageSwift() -> String {
        return """
        // swift-tools-version: 6.2
        // \(projectName) — MCP 서버

        import PackageDescription

        let package = Package(
            name: "\(projectName)",
            platforms: [
                .macOS(.v14)
            ],
            dependencies: [],
            targets: [
                .executableTarget(
                    name: "\(projectName)",
                    dependencies: [],
                    path: "Sources/\(projectName)",
                    swiftSettings: [
                        .swiftLanguageMode(.v6)
                    ]
                )
            ]
        )
        """
    }

    /// main.swift 템플릿 — MCP 서버 stdin/stdout JSON-RPC 루프
    func mainSwift() -> String {
        return """
        // main.swift
        // \(projectName) MCP 서버
        // stdin에서 JSON-RPC 2.0 요청 읽기 → 처리 → stdout 출력

        import Foundation

        // MCP 서버 초기화 및 실행
        // MCPServer는 actor이지만 run()은 nonisolated — 블로킹 stdin 루프 직접 호출 가능
        let server = MCPServer()
        server.run()
        """
    }

    /// MCPProtocol.swift 템플릿 — JSON-RPC 2.0 기본 구현
    func mcpProtocolSwift() -> String {
        return """
        // MCPProtocol.swift
        // JSON-RPC 2.0 MCP 프로토콜 구현
        // initialize → tools/list → tools/call 핸들링

        import Foundation

        /// MCP tool 프로토콜 — 순수 기능이므로 nonisolated struct로 구현 권장
        protocol MCPTool: Sendable {
            var name: String { get }
            var description: String { get }
            var inputSchema: [String: Any] { get }
            func call(arguments: [String: Any]) -> String
        }

        /// MCP 서버 핵심 구현
        /// actor 사용: initialized 상태를 안전하게 관리하는 유일한 mutable 지점
        actor MCPServer {
            private let tools: [String: any MCPTool]
            private var initialized = false

            init() {
                // 여기에 tool 등록
                let sampleTool = SampleTool()
                self.tools = [sampleTool.name: sampleTool]
            }

            /// 서버 메인 루프 — stdin에서 JSON 요청 읽기 (nonisolated: stdin 블로킹 루프)
            nonisolated func run() {
                while let line = readLine(strippingNewline: true) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }

                    guard let data = trimmed.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          json["jsonrpc"] as? String == "2.0" else {
                        sendError(id: nil, code: -32700, message: "Parse error")
                        continue
                    }

                    let id = json["id"]
                    let method = json["method"] as? String ?? ""
                    let params = json["params"] as? [String: Any]

                    // actor 메서드를 동기적으로 호출 (메인 스레드 없는 CLI 환경)
                    let semaphore = DispatchSemaphore(value: 0)
                    Task {
                        await handleRequest(id: id, method: method, params: params)
                        semaphore.signal()
                    }
                    semaphore.wait()
                }
            }

            private func handleRequest(id: Any?, method: String, params: [String: Any]?) {
                switch method {
                case "initialize":
                    sendResult(id: id, result: handleInitialize())
                    initialized = true

                case "initialized":
                    break // notification — 응답 없음

                case "tools/list":
                    guard initialized else {
                        sendError(id: id, code: -32002, message: "Not initialized")
                        return
                    }
                    sendResult(id: id, result: handleToolsList())

                case "tools/call":
                    guard initialized else {
                        sendError(id: id, code: -32002, message: "Not initialized")
                        return
                    }
                    sendResult(id: id, result: handleToolsCall(params: params))

                default:
                    sendError(id: id, code: -32601, message: "Method not found: \\(method)")
                }
            }

            private func handleInitialize() -> [String: Any] {
                return [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "\(projectName)", "version": "1.0.0"]
                ]
            }

            private func handleToolsList() -> [String: Any] {
                let toolDefs = tools.values.map { tool -> [String: Any] in
                    return [
                        "name": tool.name,
                        "description": tool.description,
                        "inputSchema": tool.inputSchema
                    ]
                }
                return ["tools": toolDefs]
            }

            private func handleToolsCall(params: [String: Any]?) -> [String: Any] {
                guard let name = params?["name"] as? String,
                      let tool = tools[name] else {
                    return makeError("Unknown tool")
                }

                let args = params?["arguments"] as? [String: Any] ?? [:]
                let result = tool.call(arguments: args)
                return ["content": [["type": "text", "text": result]]]
            }

            nonisolated private func sendResult(id: Any?, result: [String: Any]) {
                var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
                response["id"] = id
                outputJSON(response)
            }

            nonisolated private func sendError(id: Any?, code: Int, message: String) {
                var response: [String: Any] = [
                    "jsonrpc": "2.0",
                    "error": ["code": code, "message": message]
                ]
                response["id"] = id
                outputJSON(response)
            }

            nonisolated private func outputJSON(_ dict: [String: Any]) {
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let str = String(data: data, encoding: .utf8) {
                    print(str)
                    fflush(stdout)
                }
            }

            private func makeError(_ message: String) -> [String: Any] {
                return ["content": [["type": "text", "text": "오류: \\(message)"]], "isError": true]
            }
        }
        """
    }

    /// SampleTool.swift 템플릿
    func sampleToolSwift() -> String {
        return """
        // SampleTool.swift
        // 샘플 MCP tool 구현 — echo 기능

        import Foundation

        /// Echo 샘플 tool
        struct SampleTool: MCPTool {
            let name = "echo"
            let description = "입력한 메시지를 그대로 반환합니다"

            var inputSchema: [String: Any] {
                return [
                    "type": "object",
                    "properties": [
                        "message": [
                            "type": "string",
                            "description": "반환할 메시지"
                        ]
                    ],
                    "required": ["message"]
                ]
            }

            func call(arguments: [String: Any]) -> String {
                let message = arguments["message"] as? String ?? "(메시지 없음)"
                return "Echo: \\(message)"
            }
        }
        """
    }

    /// .github/workflows/release.yml 템플릿
    /// GitHub Actions: tag push → macOS arm64/x86_64 빌드 → GitHub Releases 업로드
    func githubActionsYml() -> String {
        return """
        name: Release

        on:
          push:
            tags:
              - 'v*'

        jobs:
          build:
            strategy:
              matrix:
                include:
                  - os: macos-14
                    arch: arm64
                    artifact: \(projectName)-macos-arm64.tar.gz
                  - os: macos-13
                    arch: x86_64
                    artifact: \(projectName)-macos-x86_64.tar.gz

            runs-on: ${{ matrix.os }}

            steps:
              - uses: actions/checkout@v4

              - name: Swift 빌드 (릴리스)
                run: swift build -c release --product \(projectName)

              - name: 아카이브 생성
                run: |
                  cd .build/release
                  tar -czf ${{ matrix.artifact }} \(projectName)

              - name: GitHub Releases 업로드
                uses: softprops/action-gh-release@v1
                with:
                  files: .build/release/${{ matrix.artifact }}
                env:
                  GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        """
    }

    /// registry-entry.json 템플릿
    func registryEntryJson() -> String {
        return """
        {
          "repo": "YOUR_GITHUB_USERNAME/\(projectName)",
          "description": "\(projectDescription)",
          "executable": "\(projectName)",
          "platforms": {
            "macos-arm64": {
              "artifact": "\(projectName)-macos-arm64.tar.gz"
            },
            "macos-x86_64": {
              "artifact": "\(projectName)-macos-x86_64.tar.gz"
            }
          },
          "source": {
            "buildPath": ".",
            "buildCommand": "swift build -c release",
            "product": "\(projectName)"
          }
        }
        """
    }

    /// README.md 템플릿
    func readmeMd() -> String {
        return """
        # \(projectName)

        \(projectDescription)

        ## 설치

        ```bash
        swiftmcp install \(projectName)
        ```

        ## 실행

        ```bash
        swiftmcp run \(projectName)
        ```

        ## Claude Code MCP 등록

        ```bash
        claude mcp add \(projectName) -- swiftmcp run \(projectName)
        ```

        ## 개발

        ```bash
        swift build
        .build/debug/\(projectName)
        ```

        ## 빌드 (릴리스)

        ```bash
        swift build -c release
        ```
        """
    }

    /// .gitignore 템플릿
    func gitignore() -> String {
        return """
        .build/
        .swiftpm/
        *.xcodeproj
        DerivedData/
        .DS_Store
        """
    }
}
