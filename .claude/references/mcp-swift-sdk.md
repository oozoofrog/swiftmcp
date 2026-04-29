---
library: mcp-swift-sdk
version: "0.11.x (pre-1.0)"
spec_version: "2025-11-25"
collected: "2026-04-30"
sources:
  - github: "https://github.com/modelcontextprotocol/swift-sdk"
  - spec: "https://modelcontextprotocol.io/specification/2025-11-25"
---

# MCP Swift SDK

## Requirements

- Swift 6.0+, Xcode 16+
- macOS 13+, iOS 16+, Linux (glibc/musl)
- 사양: MCP 2025-11-25

## Package

```swift
.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
```

타깃 의존성에 product `"MCP"`를 추가.

> SDK는 pre-1.0. minor 버전 변경 시 API breaking change 가능. **`up-to-next-minor`로 핀**하는 것이 안전.

## Server 생성

```swift
import MCP

let server = Server(
    name: "MyModelServer",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: true))
)
```

## 메서드 핸들러 등록

```swift
await server.withMethodHandler(ListTools.self) { _ in
    return .init(tools: [
        Tool(
            name: "weather",
            description: "Get current weather for a location",
            inputSchema: .object([...])
        )
    ])
}

await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case "weather":
        let location = params.arguments?["location"]?.stringValue ?? "Unknown"
        return .init(
            content: [.text("Weather for \(location): 72°F")],
            isError: false
        )
    default:
        return .init(content: [.text("Unknown tool")], isError: true)
    }
}
```

## Stdio Transport

```swift
let transport = StdioTransport()
try await server.start(transport: transport)
```

stdio 위 JSON-RPC. **stdout 오염 절대 금지** — 모든 비-MCP 출력은 stderr 또는 파일로.

## 도구 정의 (`tools/list`)

응답 스키마:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "tools": [
      {
        "name": "get_weather",
        "title": "Weather Information Provider",
        "description": "Get current weather information for a location",
        "inputSchema": {
          "type": "object",
          "properties": { "location": { "type": "string" } },
          "required": ["location"]
        },
        "icons": [{ "src": "...", "mimeType": "image/png", "sizes": ["48x48"] }],
        "execution": { "taskSupport": "optional" }
      }
    ],
    "nextCursor": "next-page-cursor"
  }
}
```

- `inputSchema`는 JSON Schema. 서버 측에서 `[String: Value]`로 받음.
- `execution.taskSupport`: `"required" | "optional" | "none"` — long-running 도구 표시.
- pagination은 `nextCursor` (도구 수가 많을 때).

## 도구 호출 (`tools/call`)

요청:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": { "name": "get_weather", "arguments": { "location": "New York" } }
}
```

응답:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [
      { "type": "text", "text": "Current weather in New York: ..." }
    ],
    "isError": false
  }
}
```

- `content` 항목 타입: `text`, 그 외(이미지·resource link 등) 사양에 정의.
- `isError: true`는 도구 *실행* 단계에서 발생한 에러.

## 에러 처리 (이중 채널)

| 카테고리 | 메커니즘 | 우리 사용 |
|---|---|---|
| Protocol Error | JSON-RPC error 객체 (`-32602` 등) | 인자 스키마 위반, 알 수 없는 도구 |
| Tool Execution Error | result `isError: true` + content | 외부 프로세스 실행 실패, sandbox 거부, timeout |
| Tool Result (success) | result `isError: false` + content | 컴파일러 진단(에러·워닝)도 *정상 결과*. 진단을 content로 반환 |

핵심 원칙: **사용자 Swift 코드가 컴파일 에러를 내는 것은 도구 실패가 아니다.** 정적 분석 도구는 진단을 얻는 게 목적이므로 success로 보고하고 content에 진단을 담는다.

## SDK 사용 시 주의

- **stdout은 프로토콜 채널** — `print`, `FileHandle.standardOutput`로 진단 메시지 쓰면 클라이언트 파싱 실패. 로그는 stderr 또는 파일.
- **`StdioTransport`의 cancel/timeout 처리**: SDK 0.11.x 기준 정확한 cancel·progress 지원 범위는 코드 확인 필요. 도구 호출이 외부 프로세스를 실행할 때 중단 신호를 어디까지 전달하는지 검증 후 결정.
- **`Tool.inputSchema`는 `Value` 타입**: SDK는 자체 `Value` 타입(JSON 동등)을 사용. Codable 자동 매핑이 아니라, 요청 인자는 dict 형태로 받아 직접 디코드.
- **`execution.taskSupport`가 `"required"`인 경우**: 클라이언트가 long-running task를 처리해야 호출됨. 격리 빌드/실행 도구는 이 마커를 사용해 클라이언트가 cancel 가능하게 노출.
- **pre-1.0 의존성**: minor 버전 업그레이드 시 README/Examples 재확인.
