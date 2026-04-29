# swiftmcp — Implementation Plan

이 문서는 본 MCP의 단계별 구현 계획입니다. 각 Stage는 검증 가능한 종료 조건을 가지며, 다음 Stage는 이전 Stage의 인프라를 그대로 재사용합니다.

배경 자료:
- `.claude/references/swiftc.md` — swiftc 옵션 전체
- `.claude/references/swift-static-analysis.md` — 분석 카탈로그
- `.claude/references/mcp-swift-sdk.md` — SDK API 및 MCP 사양

## 0. 결정 사항

다음은 합의된 결정으로, 변경 시 PLAN을 갱신해야 합니다.

### 0.1 형태

- **MCP 서버를 1차 진입점**으로 둔다. CLI는 후순위.
- 코어 로직은 **`SwiftcMCPCore` 라이브러리 타깃**에 분리한다. 진입점은 라이브러리의 얇은 어댑터.
- 진입점 바이너리 이름은 **`mcpswx`** (사전 합의).

### 0.2 의존성

- 빌드 시스템: **Swift Package Manager** (`Package.swift`).
- 컴파일러 호출 대상: 시스템에 설치된 **`swiftc` / `swift-frontend`**. 본 MCP는 Swift 컴파일러 소스 트리를 임베드하지 않는다.
- MCP 라이브러리: **`modelcontextprotocol/swift-sdk`** product `MCP`, 버전 `up-to-next-minor: 0.11.0`.
- 최소 환경: Swift 6.0+, macOS 13+ (현재 toolchain Swift 6.3.1 / Xcode 26 / arm64-apple-macosx26).

### 0.3 통신 규약

- stdio 위 JSON-RPC. **stdout은 프로토콜 채널** — 진단 메시지는 stderr 또는 파일.
- 에러 분리 (사양상의 두 채널을 다음과 같이 매핑):
  - **Protocol Error** — 인자 스키마 위반, 알 수 없는 도구.
  - **Tool Execution Error** (`isError: true`) — 외부 프로세스 호출 실패, sandbox 거부, timeout.
  - **Tool Result success** — 사용자 Swift 코드의 컴파일 진단(에러·워닝 포함). 진단 자체가 산출물이므로 success로 보고하고 content에 담는다.

### 0.4 응답 크기 정책

- 도구 응답이 LLM 컨텍스트로 들어가므로 큰 텍스트 산출물(SIL/AST/IR/모듈 trace 등)은 본문에 포함하지 않는다.
- 패턴: **임시 파일에 산출물 저장 → content에는 파일 경로 + 요약 통계만 반환.**
- 임시 파일은 **호출당 격리 디렉토리** (`$TMPDIR/swiftmcp-<call-id>/`)에 두고, 도구 호출 종료 시 retention 정책에 따라 정리.

### 0.5 입력 도메인 (목표)

본 MCP가 최종적으로 받을 입력은 다음 6단계:
단일 파일 → 소스 디렉토리 → Swift 모듈 → SwiftPM 패키지 → Xcode project → Xcode workspace.

각 도구는 6단계 중 어느 입력에서 동작 가능한지를 메타데이터로 노출한다. Stage별 확장은 이 6단계 축을 따라간다.

### 0.6 타깃 플랫폼 (분석 대상 코드의 플랫폼)

본 MCP가 분석할 수 있는 코드의 타깃: macOS, iOS, iPadOS, watchOS, tvOS, visionOS, simulator 변형, macCatalyst.

본 MCP 자체가 실행되는 호스트는 macOS 13+. 분석 대상의 plat과 호스트는 분리된 개념.

## 1. 패키지 구조

```
swiftmcp/
├── Package.swift
├── Sources/
│   ├── SwiftcMCPCore/       # library product
│   │   ├── Toolchain/       # swiftc 호출 추상화, 합성 입력, 산출물 회수
│   │   ├── Execution/       # 격리 빌드/실행 인프라 (Stage 1+에서 채움)
│   │   ├── Tools/           # 개별 분석 도구 모듈 (도구당 1파일 원칙)
│   │   ├── Diagnostics/     # 컴파일러 진단 파싱
│   │   └── Result/          # Codable 응답 타입
│   └── mcpswx/              # executable product
│       ├── main.swift       # SDK Server + StdioTransport 부트스트랩
│       └── ToolRegistry.swift  # 라이브러리 도구를 SDK Tool로 노출
└── Tests/
    └── SwiftcMCPCoreTests/
```

원칙:
- `mcpswx`는 SDK와 라이브러리를 잇는 어댑터만 둔다. 비즈니스 로직 없음.
- 도구 1개 = `SwiftcMCPCore/Tools/` 1파일 + 테스트 1파일.
- 외부에 노출되는 결과 타입은 모두 `Codable`. 직접 JSON Schema를 손으로 쓰지 않고 자동 매핑.

## 2. Stage 0 — 인프라

### 2.1 종료 조건

- `swift build`가 성공한다.
- `mcpswx`가 stdio MCP 서버로 동작한다 (`tools/list`, `tools/call`이 응답).
- 검증용 도구 **`print_target_info`** 1개가 동작한다 — 입력으로 triple을 받아 `swiftc -print-target-info -target <triple>`을 호출하고 stdout JSON을 그대로 content로 반환.
- 이 한 도구로 검증되는 인프라:
  - SPM 두 타깃 분리
  - SDK Server / StdioTransport 부트스트랩
  - 외부 프로세스 호출 추상화 (toolchain resolver, 인자 조립, stdout/stderr 분리, exit code, timeout)
  - 임시 디렉토리 정책 (이 도구는 산출물 없음 — 정책 골격만 마련)
  - 에러 채널 매핑 (잘못된 triple 인자 → Protocol Error 또는 Tool Result `isError`)
  - stderr 로그 라우팅

### 2.2 구체 작업

1. `Package.swift` 생성 — library + executable 두 product, swift-sdk 의존성, Swift tools 6.0.
2. `SwiftcMCPCore/Toolchain/` — `ToolchainResolver` (xcrun 우선, `TOOLCHAINS` env 우선순위 결정), `SwiftcInvocation` (인자 빌드 + 외부 프로세스 실행 + 결과 회수).
3. `SwiftcMCPCore/Result/` — 도구 결과 공통 타입 (`ToolOutput`, `ProcessResult`, `Diagnostic`).
4. `SwiftcMCPCore/Tools/PrintTargetInfo.swift` — 첫 도구 구현.
5. `mcpswx/main.swift` — Server 부트스트랩, ListTools/CallTool 핸들러 등록, StdioTransport 시작.
6. `mcpswx/ToolRegistry.swift` — 라이브러리 도구 → SDK Tool 매핑.
7. 테스트:
   - `ToolchainResolver`가 시스템 swiftc를 찾아낸다.
   - `SwiftcInvocation`이 `--version` 호출에 성공한다.
   - `PrintTargetInfo` 도구가 유효 triple에 대해 JSON을 반환한다.
   - 잘못된 triple에 대해 Tool Result에 컴파일러 stderr를 담는다.

### 2.3 결정 미뤄둠 (Stage 0 진입 시 결정)

- 임시 파일 retention 정책의 정확한 모양 (호출 종료 시 즉시 삭제 vs TTL 기반).
- SDK 0.11.x의 cancel/progress 지원 범위 — 코드를 보고 어디까지 신호 전달이 가능한지 확인 후, Stage 1의 long-running 도구가 어떻게 cancel을 노출할지 결정.

## 3. Stage 1 — 단일 파일 입력 + 첫 도구들

### 3.1 종료 조건

다음 4개 도구가 단일 `.swift` 파일 입력에 대해 동작한다.

1. **`find_slow_typecheck`** — 표현식·함수 본문 type-check 시간 진단을 임계값(ms)으로 받아 `[{file,line,col,ms,kind}]` 반환.
   - 호출: `swiftc -typecheck -Xfrontend -warn-long-expression-type-checking=<ms> -Xfrontend -warn-long-function-bodies=<ms> <file>`
   - 출력은 stderr의 워닝 라인 파싱.

2. **`emit_ast`** / **`emit_sil`** / **`emit_ir`** — AST/SIL/IR 추출. 산출물은 임시 파일에 저장, content는 경로 + 크기 요약.
   - AST: `-dump-ast` 텍스트 또는 `-dump-ast -dump-ast-format json`. **JSON 포맷 비안정성 메타에 명시.**
   - SIL: `-emit-silgen` (raw), `-emit-sil` (canonical), `-emit-sil -O` (optimized). 호출자가 단계 선택.
   - IR: `-emit-irgen` (pre-LLVM-opt), `-emit-ir` (post-LLVM-opt), `-emit-bc` (bitcode).

3. **`build_isolated_snippet`** — 클라이언트가 합성한 Swift 코드를 받아 격리 빌드/실행하고 stdout/stderr/exit code 반환.
   - 가벼운 경로: `swiftc -frontend -interpret <synthesized.swift>` — 빌드 산출물 없이 즉시 실행.
   - 무거운 경로: `swiftc -o <tmp>/exe <synthesized.swift>` 후 별도 프로세스로 실행 — sandbox/timeout 풍부 적용.
   - Stage 1은 가벼운 경로 1개로 시작. 무거운 경로는 Stage 2+에서 추가.
   - 입력은 클라이언트가 합성한 단일 텍스트. Stage 1은 슬라이싱·stub 자동 생성 없음.

### 3.2 검증 항목

- type-check 워닝 파싱이 다양한 위치 형식(파일/함수/표현식)에서 안정적인가.
- AST/SIL/IR 산출물이 임시 디렉토리에 격리되며, 호출 종료 후 정리되는가.
- `build_isolated_snippet`의 stdout/stderr 캡처가 stdio 프로토콜 채널과 충돌하지 않는가 (격리 실행은 *자식* 프로세스, MCP는 *부모* 프로세스).
- timeout 도달 시 자식 프로세스가 깔끔히 종료되고 결과에 timeout 마커가 담기는가.
- cancel 신호가 도구 호출 중에 전달되었을 때 자식 프로세스도 종료되는가 (SDK 지원 범위 확인 결과에 의존).

### 3.3 결정 미뤄둠

- `build_isolated_snippet`의 sandbox 정책 — `-disable-sandbox` 사용 여부, 자식 프로세스에 환경변수·작업 디렉토리 차단을 어디까지 적용할지.
- 컴파일러 진단을 도구 결과의 어떤 모양으로 정규화할지 (라인 텍스트 그대로 vs. 파싱된 구조).

## 4. Stage 1 종료 후 분기점

Stage 1을 끝낸 시점에 두 갈래 중 하나를 선택한다. 지금 시점에 결정하지 않는다.

- **갈래 A — 도구 폭 확장 (같은 단일 파일 입력 유지)**: `compile_stats`, `call_graph`, `concurrency_audit`, `api_surface`. 인프라 변경 거의 없음.
- **갈래 B — 입력 폭 확장 (도구는 Stage 1의 4개 유지)**: 소스 디렉토리 → Swift 모듈 → SwiftPM 패키지 입력 단계 추가. 각 단계마다 컴파일러 인자 추출 경로 1개씩 추가.

선택 기준:
- Stage 1 종료 시점에 어느 도구가 사용자 시나리오에서 더 자주 호출되는지가 보이면 그 갈래 우선.
- 두 갈래는 직교라 두 번째 갈래는 첫 번째 후 그대로 진행 가능.

## 5. Stage 2+ (윤곽만)

- 입력 확장: 소스 디렉토리 (같은 모듈 가정) → Swift 모듈 (`-module-name` + search path) → SwiftPM 패키지 (`swift package describe --type json`) → Xcode project (`xcodebuild -showBuildSettings`) → Xcode workspace (scheme 선택).
- 도구 추가: `compile_stats`, `call_graph`, `module_import_diff`, `api_surface`, `api_diff`, `concurrency_audit`, `xcbuild_perf`.
- 격리 실행 고도화: 슬라이싱(`slice_function`) → stub 후보 자동 생성(`extract_with_stubs`) → 빌드 시도 → 누락 심볼 보고 → 클라이언트(LLM) stub 보강 → 재시도 루프.

각 Stage 진입 시 상기 4번의 분기점 결정과 동일한 절차로 PLAN을 갱신한다.

## 6. 비-Stage 정책

다음은 모든 Stage에 적용되는 정책이다.

- **Toolchain 해석 우선순위**: `TOOLCHAINS` env → `xcrun -f swiftc` → `PATH`. 결과 toolchain 경로와 버전을 모든 도구 응답의 메타에 포함.
- **AST/SIL 포맷 비안정성**: 외부에 산출물을 노출할 때 toolchain 버전을 함께 반환. 컴파일러 버전 간 포맷 호환을 약속하지 않는다.
- **호출별 임시 디렉토리**: `$TMPDIR/swiftmcp-<uuid>/`. 호출 종료 시 정리.
- **컴파일러 호출 vs 빌드**: 분석 호출(`-typecheck` 등)은 오브젝트 산출 없이 끝나도록 한다. 빌드 캐시 오염 방지.
- **stdio 분리**: 자식 프로세스 stdout/stderr는 부모 stdio와 절대 섞이지 않는다 (FileHandle pipe 사용).
- **인자 검증**: `swiftc -frontend -emit-supported-arguments`로 받은 토큰 화이트리스트로 동적 검증. 사용자 입력 옵션은 화이트리스트 통과 후 호출.
- **Hidden 옵션 노출 정책**: 본 MCP가 외부에 인자로 노출하는 화이트리스트는 `swiftc --help` 기준. `-help-hidden`/`-frontend -help-hidden`의 옵션은 도구 내부에서만 사용. 사용자가 임의 옵션을 패스하는 채널은 두지 않는다 (escape hatch가 필요해지면 명시적 도구로 추가).

## 7. Open Questions

다음은 현재 시점에 결정하지 않는 항목입니다. Stage 진입 시 또는 외부 사실 확인 후 결정합니다.

- SDK 0.11.x의 정확한 cancel/progress 동작 (코드 확인 필요).
- 임시 파일 retention TTL.
- `build_isolated_snippet`이 Stage 1에서 무엇을 sandbox로 막을지의 구체 목록.
- CLI 진입점(`mcpswx-cli`)의 도입 시점 — Stage 1 종료 후 재검토.
- Stage 6+ 의 "playground/실행 모델 추가"가 본 MCP에 흡수될지, 별도 서버로 분리될지 — Stage 5 종료 후 결정.

## 8. 진행 규칙

- Stage 종료 조건은 검증 명령(빌드·테스트·실행)으로 표현되어야 한다. "거의 다 됐다"는 종료가 아니다.
- Stage 진입 전 PLAN을 읽고, 종료 후 PLAN을 갱신한다.
- 결정 항목을 변경할 때는 본 문서의 해당 절을 새로 쓴 형태로 교체한다 (이력은 git에 둔다).
