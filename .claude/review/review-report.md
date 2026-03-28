# Code Review Report

## 개요

- 리뷰 대상: oozoofrog/swiftmcp 전체 코드베이스 (22개 Swift 파일)
- 리뷰 일시: 2026-03-27
- 리뷰 초점: Apple 에코시스템 + 코드 품질 + 보안 + 스타일
- 참조 문서: `references/common-mistakes.md`, `references/code-style.md`, `references/swift-concurrency.md`
- Xcode MCP: 미연결

## 요약

| Severity | 건수 | 자동 수정 | GitHub Issue 후보 | 사용자 결정 | 보고만 |
|----------|------|----------|-----------------|-----------|--------|
| Critical | 0 | - | - | - | - |
| Major | 5 | 2 (R003, R004) | 3 (R001, R002, R005) | - | - |
| Minor | 4 | - | 2 (R006, R009) | - | 2 (R007, R008) |
| Suggestion | 2 | - | - | - | 2 (R010, R011) |

**특이사항**: 플랜 모드 활성화로 인해 R003, R004의 실제 코드 수정은 실행되지 않았습니다. 수정 내용은 아래에 상세히 기술합니다.

---

## 자동 수정 필요 (플랜 모드로 미실행)

### R003: outputJSON 인코딩 실패 시 클라이언트 hang 위험 (MCPServerHandler.swift:208)

- **문제**: `try? encoder.encode(dict)` 실패 시 stdout에 아무것도 출력하지 않아 MCP 클라이언트가 응답을 무한 대기합니다. JSON-RPC 2.0 프로토콜 위반입니다.
- **참조**: `references/common-mistakes.md` — Swift 6.2 Concurrency
- **수정 내용**:

```swift
// Before
private func outputJSON(_ dict: [String: JSONValue]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = []
    if let data = try? encoder.encode(dict),
       let str = String(data: data, encoding: .utf8) {
        print(str)
        fflush(stdout)
    }
}

// After
private func outputJSON(_ dict: [String: JSONValue]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = []
    if let data = try? encoder.encode(dict),
       let str = String(data: data, encoding: .utf8) {
        print(str)
        fflush(stdout)
    } else {
        // 인코딩 실패 시 fallback 에러 응답으로 클라이언트 hang 방지
        let fallback = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error: response serialization failed\"}}\n"
        fputs(fallback, stdout)
        fflush(stdout)
    }
}
```

### R004: BinaryResolver.detectPlatform()에서 try? process.run() 사용 (BinaryResolver.swift:41)

- **문제**: arch 명령 실행 실패를 try?로 무시합니다. 실패 시 빈 문자열이 아닌 컴파일 타임 폴백으로 즉시 이동하는 로직이 더 명확합니다.
- **참조**: `references/common-mistakes.md` — Swift 6.2 Concurrency
- **수정 내용**:

```swift
// Before
try? process.run()
process.waitUntilExit()

let data = pipe.fileHandleForReading.readDataToEndOfFile()
let arch = String(data: data, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

// After
guard (try? process.run()) != nil else {
    // 실행 파일 실행 불가 시 컴파일 타임 감지로 즉시 폴백
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
```

---

## GitHub Issue 후보

### R001: 템플릿 코드에 DispatchSemaphore 블로킹 패턴 포함 (PackageTemplate.swift:102)

- **문제**: `swiftmcp init`으로 생성되는 `MCPProtocol.swift` 템플릿에 `DispatchSemaphore.wait()`로 async `Task`를 블로킹하는 안티패턴이 포함되어 있습니다. Swift 6.2 + swift-tools-version 6.2로 생성되는 프로젝트에서 cooperative thread pool 고갈을 유발할 수 있으며, 생성된 코드를 사용하는 모든 사용자에게 이 패턴이 전파됩니다.
- **참조**: `references/swift-concurrency.md` — "Offloading work to the background"
- **수정 방향**: 템플릿의 `nonisolated func run()`을 `async`로 변경하고, `@main struct`를 `AsyncParsableCommand` 패턴(본 프로젝트의 `MCPCommand`와 동일한 방식)으로 재작성. `MCPServer` actor의 stdin 루프도 async 체인으로 전환.

### R002: buildCommand 공백 split으로 인한 인수 주입 취약점 (SourceResolver.swift:46)

- **문제**: 레지스트리 JSON의 `buildCommand` 문자열을 단순 공백 기준 `.split(separator: " ")`으로 파싱하여 `Process.arguments`에 직접 전달합니다. 공격자가 레지스트리를 조작하거나 MITM 공격에 성공하면 임의 빌드 인수를 주입할 수 있습니다. 또한 따옴표 포함 인수(따옴표 처리 없음), 셸 메타문자 처리가 없어 의도치 않은 동작이 발생합니다.
- **참조**: `references/common-mistakes.md`
- **수정 방향**: 레지스트리 스키마에서 `buildCommand` 문자열을 `buildArguments: [String]` 배열로 변경(하위 호환 필요 시 둘 다 지원). 단기적으로는 실행 파일을 화이트리스트("swift", "xcodebuild"만 허용)로 검증하고, GitHub URL 다운로드에 HTTPS 고정 및 체크섬 검증을 추가.

### R005: 압축 해제 후 첫 번째 파일 무조건 실행 가능 처리 (CacheManager.swift:83)

- **문제**: `executableName`으로 바이너리를 찾지 못하면 디렉토리 내 `contents.first`에 chmod +x를 적용하고 실행합니다. 악성 tar.gz가 예상치 못한 파일명을 포함할 경우, 잘못된 파일에 실행 권한이 부여됩니다. 이 분기는 `executableName` 검증을 완전히 우회합니다.
- **참조**: `references/common-mistakes.md`
- **수정 방향**: 폴백 분기 제거. `executableName`과 정확히 일치하는 파일만 허용. 다운로드된 artifact의 SHA256 체크섬을 레지스트리에 기록하고 검증하는 무결성 확인 추가.

### R006: raw mode 중 SIGINT 수신 시 tcsetattr 복원 누락 위험 (InteractiveMenu.swift:37~49)

- **문제**: `selectMenu()`에서 `tcsetattr`로 raw mode에 진입한 후 `defer`로 복원을 등록합니다. 그러나 `read(STDIN_FILENO, ...)` 블로킹 중 Ctrl-C(SIGINT)를 수신하면 기본 핸들러가 프로세스를 종료하며 `defer`가 실행되지 않습니다. 터미널이 raw mode로 남으면 셸이 키 입력을 정상 처리하지 못합니다(`stty sane`으로 수동 복구 필요).
- **참조**: `references/code-style.md` — Apple Code Style
- **수정 방향**: `signal(SIGINT, ...)` 핸들러에서 `tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)`를 명시적으로 호출 후 재raise. 또는 `atexit()` 등록으로 프로세스 종료 시 터미널 상태 복원 보장.

### R009: 생성 템플릿 Swift 6 strict concurrency 빌드 오류 위험 (PackageTemplate.swift:91)

- **문제**: R001과 연계. 생성된 `MCPProtocol.swift`에서 actor `MCPServer`의 `nonisolated func run()`이 `Task { await handleRequest(...) }`를 사용합니다. Swift 6 (`swiftLanguageMode(.v6)`)에서 `nonisolated` 컨텍스트에서 actor-isolated `handleRequest`로의 Task 생성이 `Sendable` 위반 경고 또는 에러를 유발할 수 있습니다. `swiftmcp init`으로 생성 즉시 빌드 실패를 경험하게 됩니다.
- **참조**: `references/swift-concurrency.md` — "Global State"
- **수정 방향**: R001과 함께 템플릿을 async 기반으로 전면 재작성.

---

## 보고 (minor, 수정 여부 사용자 결정)

### R007: InstallCommand에서 이미 설치된 경우 출력 불일치 (InstallCommand.swift:57)

- **문제**: 이미 설치된 경우 stderr.write()로 상태를 출력하고 경로를 `print()`로 별도 출력합니다. 신규 설치 경로(line 72)에서 `print("Installed to: ...")`를 사용하는 것과 일관성이 없습니다. MCP 통신에는 영향 없으나 스크립트 파싱 시 혼란을 줄 수 있습니다.
- **수정 방향**: line 57-58의 `print("설치 경로: \(cachedPath)")`를 `print("Installed to: \(cachedPath)")`로 통일하거나 반대로 신규 설치도 한국어로 통일.

### R008: sendResult/sendError에서 notification 응답 방지 로직 명시 부재 (MCPServerHandler.swift:169)

- **문제**: `"initialized"` notification 처리는 `break`로 올바르게 응답하지 않습니다. 그러나 `sendResult(id: nil, ...)`를 호출하면 `id: .null`을 포함한 응답을 전송하게 됩니다. 현재 코드에서 notification에 대해 `sendResult`를 호출하는 경로는 없으나, 미래 확장 시 실수 유발 가능성이 있습니다.
- **수정 방향**: 코드 명확성을 위해 주석으로 "notification에는 절대 sendResult/sendError를 호출하지 말 것"을 명시. 또는 `id` 파라미터를 nullable이 아닌 `JSONRPCIDValue`로 변경하여 컴파일 타임에 강제.

---

## 참고 사항 (suggestion)

### R010: buildExecutable 경로 결정 시 PATH 무시 (SourceResolver.swift:53)

- **제안**: `buildExecutableName`이 상대 경로이면 `/usr/bin/{name}`으로 강제하여 Homebrew(`/opt/homebrew/bin/swift`) 등 비표준 위치의 실행 파일을 사용할 수 없습니다. `which swift`나 `PATH` 환경변수 탐색으로 개선 가능합니다.
- **참조**: `references/code-style.md`

### R011: Command struct들에 nonisolated 미적용 (RunCommand.swift 외)

- **제안**: 프로젝트 규칙에 따르면 nonisolated struct 우선이나, `AsyncParsableCommand`는 ArgumentParser 프레임워크가 actor isolation을 관리하므로 적용 불필요. 현 상태가 올바릅니다. 문서화 목적으로만 포함.
- **참조**: `references/swift-concurrency.md`

---

## 특별 검증 포인트 결과

### 1. stdio 패스스루가 stdout을 오염시키는지

**양호**: `StderrWriter`를 통해 모든 진행 상황 메시지가 `stderr`로 출력됩니다. `MCPServerHandler.outputJSON()`은 `print()` + `fflush(stdout)`으로 JSON-RPC 응답만 stdout에 출력합니다. `ProcessRunner.run()`은 하위 프로세스의 stdout을 상속하며, MCP 통신 시 swiftmcp 자체 메시지는 stdout에 출력하지 않습니다.

**단, R003**: 인코딩 실패 시 아무것도 출력하지 않는 문제 → 수정 필요.

### 2. Swift 6.2 strict concurrency 위반

**대체로 양호**: 모든 핵심 타입이 `nonisolated struct + Sendable`으로 선언되어 있습니다. Package.swift에 `.swiftLanguageMode(.v6)` 설정이 있습니다.

**단, R001/R009**: 생성 템플릿(PackageTemplate.swift)의 DispatchSemaphore + actor 패턴이 Swift 6에서 빌드 오류를 유발합니다.

### 3. nonisolated struct 정책 준수

**양호**: RegistryClient, BinaryResolver, SourceResolver, CacheManager, ProcessRunner, MCPServerHandler, MCPTools, TUI 컴포넌트 모두 `nonisolated struct`로 선언되어 있습니다. `defaultIsolation: MainActor`가 없습니다.

### 4. MCP JSON-RPC 프로토콜 구현 정확성

**대체로 양호**: `initialize` → `tools/list` → `tools/call` 흐름, `ping` 지원, notification 비응답이 올바르게 구현되어 있습니다.

**개선 필요**:
- `tools/call` 결과에 `isError` 필드를 포함하는 makeError()가 MCP spec에 부합하나, `content` 없이 `isError`만 있는 경우 처리 누락.
- `initialize` 응답에 `protocolVersion: "2024-11-05"`가 하드코딩 → MCP spec 최신 버전 확인 권장.

### 5. TUI raw mode 정리(tcsetattr 복원) 누락

**부분 양호**: `defer`로 `tcsetattr` 복원이 등록되어 있어 정상 종료 시에는 복원됩니다. 그러나 **R006**: SIGINT 수신 시 복원이 보장되지 않습니다.

### 6. 보안: Process 실행 시 인자 주입 위험

**R002 (major)**: `buildCommand` 문자열을 공백 split으로 파싱하여 Process에 전달 — 개선 필요.

**R005 (major)**: 압축 해제 후 첫 번째 파일 무조건 실행 가능 처리 — 개선 필요.

**ProcessRunner.run()은 양호**: 인수를 `[String]` 배열로 받아 셸 개입 없이 직접 Process에 전달합니다. 셸 주입 위험 없음.
