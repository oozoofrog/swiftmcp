# swiftmcp — Implementation Plan

이 문서는 본 MCP의 단계별 구현 계획입니다. 각 Stage는 검증 가능한 종료 조건을 가지며, 다음 Stage는 이전 Stage의 인프라를 그대로 재사용합니다.

배경 자료:
- `.claude/references/swiftc.md` — swiftc 옵션 전체
- `.claude/references/swift-static-analysis.md` — 분석 카탈로그
- `.claude/references/mcp-spec-2025-11-25.md` — MCP 사양 + 직접 구현 가이드

## 0. 결정 사항

다음은 합의된 결정으로, 변경 시 PLAN을 갱신해야 합니다.

### 0.1 형태

- **MCP 서버를 1차 진입점**으로 둔다. CLI는 후순위.
- 코어 로직은 **`SwiftcMCPCore` 라이브러리 타깃**에 분리한다. 진입점은 라이브러리의 얇은 어댑터.
- 진입점 바이너리 이름은 **`mcpswx`** (사전 합의).

### 0.2 의존성

- 빌드 시스템: **Swift Package Manager** (`Package.swift`).
- 컴파일러 호출 대상: 시스템에 설치된 **`swiftc` / `swift-frontend`**.
- 외부 라이브러리: **없음**. MCP 2025-11-25 stdio JSON-RPC 서버를 Foundation만으로 직접 구현. 사양 문서가 1차 출처.
- 최소 환경: Swift 6.0+, macOS 13+ (현재 toolchain Swift 6.3.1 / Xcode 26 / arm64-apple-macosx26.0).

### 0.3 통신 규약

- stdio 위 JSON-RPC 2.0. 메시지 프레이밍: **줄바꿈으로 구분된 JSON** (LSP의 Content-Length 헤더 없음).
- **stdout은 프로토콜 채널** — 진단 메시지를 stdout에 쓰면 클라이언트가 파싱 실패. 로그·디버그는 stderr 또는 파일.
- 에러 채널 매핑:
  - 인자 스키마 위반·알 수 없는 도구·알 수 없는 메서드 → **JSON-RPC error** (표준 코드 `-32700`/`-32600`/`-32601`/`-32602`/`-32603`)
  - 외부 프로세스 호출 실패·sandbox 거부·timeout → **Tool Result `isError: true`**
  - 사용자 Swift 코드의 컴파일 진단(에러·워닝 포함) → **Tool Result success** + content에 진단 (정적 분석 도구의 결과는 진단 자체가 산출물)

### 0.4 응답 크기 정책

도구 응답은 LLM 컨텍스트로 들어갑니다. 큰 산출물(SIL/AST/IR/모듈 trace 등)은 **임시 파일 경로 + 요약 통계**로 반환하고 본문에 포함하지 않습니다. 임시 파일은 호출당 격리 디렉토리(`$TMPDIR/swiftmcp-<call-id>/`).

### 0.5 입력 도메인 (목표)

본 MCP가 최종적으로 받을 입력은 다음 6단계:
단일 파일 → 소스 디렉토리 → Swift 모듈 → SwiftPM 패키지 → Xcode project → Xcode workspace.

각 도구는 6단계 중 어느 입력에서 동작 가능한지를 메타데이터로 노출한다. Stage별 확장은 이 6단계 축을 따라간다.

### 0.6 타깃 플랫폼

분석 대상 코드의 타깃: macOS, iOS, iPadOS, watchOS, tvOS, visionOS, simulator 변형, macCatalyst.
호스트(본 MCP가 실행되는 곳): macOS 13+. 두 개념은 분리된 채로 다룬다.

## 1. 패키지 구조

```
swiftmcp/
├── Package.swift             # Foundation only
├── Sources/
│   ├── SwiftcMCPCore/        # library product
│   │   ├── Toolchain/        # ProcessRunner, ToolchainResolver, SwiftcInvocation
│   │   ├── Execution/        # 격리 빌드/실행 인프라 (Stage 1+)
│   │   ├── Tools/            # 개별 분석 도구 모듈 (도구당 1파일 원칙)
│   │   ├── Diagnostics/      # 컴파일러 진단 파싱 (Stage 1+)
│   │   ├── Protocol/         # JSON-RPC + MCP 메시지 + Server + StdioLoop
│   │   └── Result/           # Codable 응답 타입 (Stage 1+)
│   └── mcpswx/               # executable product
│       └── Mcpswx.swift      # @main, server 부트스트랩
└── Tests/
    └── SwiftcMCPCoreTests/
```

원칙:
- `mcpswx`는 라이브러리에 도구를 등록하고 stdio loop을 시작하는 어댑터만 둔다. 비즈니스 로직 없음.
- 도구 1개 = `SwiftcMCPCore/Tools/` 1파일 + 테스트 1파일.
- 외부에 노출되는 결과 타입은 모두 `Codable`. 와이어 포맷이 곧 결과 타입 (매핑 레이어 없음).

## 2. Stage 0 — 인프라 (완료)

종료 조건 모두 충족됨:

- ✓ `swift build` 통과, `swift test` 28개 / 4 suite 전부 통과.
- ✓ `mcpswx`가 stdio MCP 서버로 동작 (initialize / initialized / tools/list / tools/call / ping).
- ✓ `print_target_info` 도구 동작 (실제 swiftc 호출, JSON 회수).
- ✓ 외부 의존성 0.

확립된 컴포넌트:
- `Protocol/`: JSON-RPC envelope, MCP 메시지, `Server` actor, `StdioLoop` actor (TaskGroup으로 in-flight 추적, EOF 시 모두 await 후 종료).
- `Toolchain/ProcessRunner`: 외부 프로세스를 detached task에서 실행 + stdout/stderr/exit 회수.
- `Toolchain/ToolchainResolver`: `TOOLCHAINS` env → `xcrun -f swiftc` → `which` 순으로 해석, 결과 캐시.
- `Tools/PrintTargetInfo`: 첫 도구.

Stage 0 진입 시 결정된 사항:
- **임시 파일 retention**: 호출당 디렉토리(`$TMPDIR/swiftmcp-<uuid>/`)를 만들고, 도구 호출 종료 시 즉시 삭제. TTL 기반 캐시는 도입하지 않음 (요청 단위 격리가 더 단순).
- **cancellation**: `notifications/cancelled`을 Server가 받아 in-flight request id로 자식 프로세스 종료 신호로 매핑. Stage 0의 도구는 빠르게 끝나 실효 없음 — Stage 1에서 자식 프로세스 추적 인프라와 함께 도입.
- **progress**: `_meta.progressToken`은 Stage 1에서도 미사용. Stage 2의 long-running 도구 도입 시점에 검토.

## 3. Stage 1 — 단일 파일 입력 + 4개 도구 (완료)

종료 조건 모두 충족됨. 67 tests / 15 suites 통과. 노출된 도구 6개 (Stage 0의 `print_target_info` 포함):
`print_target_info`, `find_slow_typecheck`, `emit_ast`, `emit_sil`, `emit_ir`, `build_isolated_snippet`.

Cancellation 인프라가 마지막 sub-stage(1.E)에서 자리잡음:
- `Server`가 in-flight `Task`를 id별로 등록/해제, `notifications/cancelled` 도착 시 cancel.
- `runProcess` / `runProcessWithTimeout`가 `withTaskCancellationHandler` + NSLock-보호 PID 사이드 채널을 통해 자식 프로세스에 SIGTERM 전달.
- 사양 준수: cancelled 요청에는 응답을 보내지 않음 (`Task.isCancelled` 체크 + `CancellationError` 캐치 둘 다).

### 3.1 종료 조건

다음 4개 도구가 단일 `.swift` 파일 입력에 대해 동작한다.

1. **`find_slow_typecheck`**
   - 입력: `file: string`, `expression_threshold_ms: int` (기본 100), `function_threshold_ms: int` (기본 100).
   - 동작: `swiftc -typecheck -Xfrontend -warn-long-expression-type-checking=<n> -Xfrontend -warn-long-function-bodies=<n> <file>` 호출.
   - 출력: `findings` = `[{file, line, column, kind, subject, durationMs, limitMs}]`, `compilerExitCode`, `meta`.
   - **에러 채널**: 컴파일러 진단(에러·워닝)은 모두 tool result success. `compilerExitCode`로 swiftc 종료 상태를 노출. `isError: true`는 toolchain 자체를 실행할 수 없는 경우에만 throw → JSON-RPC error로 흘러간다.
   - 워닝 정규식 (확정): 단일 일반화 패턴
     `^(.+?):(\d+):(\d+): warning: (.+?) took (\d+)ms to type-check \(limit: (\d+)ms\)$`
     `subject`(예: `expression`, `global function 'compute()'`, `instance method 'foo(_:)'`)를 verbatim 보존.
     `kind`는 `subject == "expression"`이면 `"expression"`, 그 외 모두 `"function"`으로 분류.

2. **`emit_ast`** / **`emit_sil`** / **`emit_ir`** (3개 도구를 한 묶음으로 구현하되 별도 도구로 노출)
   - 입력 공통: `file: string`, `target: string?` (없으면 호스트 기본).
   - 추가 입력:
     - `emit_ast`: `format: "text" | "json" | "json-zlib"` (기본 `text`).
     - `emit_sil`: `stage: "raw" | "canonical" | "lowered"` (기본 `canonical`), `optimization: "none" | "speed" | "size" | "unchecked"` (기본 `none`).
     - `emit_ir`: `stage: "irgen" | "ir" | "bc"` (기본 `ir`), `optimization` 동일.
   - 동작: 호출당 임시 디렉토리에 산출물 파일을 떨군 뒤 경로 + 크기 + toolchain 버전을 결과로 반환. 산출물 본문은 content에 포함하지 않음 (응답 크기 정책 §0.4).
   - 출력: `result.path: string`, `result.bytes: int`, `result.toolchain: {path, version}`, `result.format_unstable: bool` (AST JSON과 SIL/IR 텍스트는 toolchain 간 호환 비보장 — 메타에 표시).
   - 상세 swiftc 매핑 (`.claude/references/swiftc.md` 참조):
     - AST text: `-dump-ast`, JSON: `-dump-ast -dump-ast-format json`.
     - SIL: `-emit-silgen` (raw), `-emit-sil` (canonical), `-emit-lowered-sil` (lowered).
     - IR: `-emit-irgen`, `-emit-ir`, `-emit-bc`.
     - optimization: `-Onone` / `-O` / `-Osize` / `-Ounchecked`.

3. **`build_isolated_snippet`**
   - 입력: `code: string` (Swift 소스), `target: string?` (없으면 호스트 기본), `timeout_ms: int?` (기본 10000), `args: string[]?` (피호출 프로그램에 전달할 `argv`).
   - 동작: 임시 디렉토리에 `<dir>/Sources/main.swift`로 코드 저장 → `swiftc -O -o <dir>/exe <dir>/Sources/main.swift` 빌드 → 빌드 성공 시 자식 프로세스로 `exe` 실행 → stdout/stderr/exit/duration 회수.
   - 가벼운 경로(`swiftc -frontend -interpret`)는 macOS 26 환경에서 stdlib 로드가 실패하는 것이 확인됨. Stage 1은 **무거운 경로(빌드+실행) 단일**로 시작.
   - 출력: 빌드 단계 진단(있으면) + 실행 stdout / stderr / exit code / 실행 시간. 빌드 실패는 Tool Result success + content에 진단 (분석 결과는 진단 자체가 산출물). 자식 프로세스 launch 실패·timeout은 `isError: true`.

### 3.2 작업 분할 (커밋 단위)

각 단계 종료 시 빌드 + 테스트 통과 검증. 단계 간 의존: 상위 단계가 모두 정상이어야 다음 진행.

#### Stage 1.A — 진단 파싱과 임시 디렉토리 인프라
- `Diagnostics/CompilerWarning.swift`: 워닝 라인 1개의 정규식 매칭 + 구조체.
- `Diagnostics/WarningParser.swift`: stderr 전체 텍스트 → `[Warning]` 추출.
- `Execution/CallScratch.swift`: 호출당 임시 디렉토리(`$TMPDIR/swiftmcp-<uuid>/`) 생성 + `defer`로 정리.
- `Result/ToolOutput.swift`: 도구 응답에 항상 포함될 메타(`toolchain`, `target`, `duration_ms`).
- 단위 테스트: 두 정규식이 sample 워닝 라인을 정확히 추출 / scratch 디렉토리가 호출 후 사라짐.

#### Stage 1.B — `find_slow_typecheck`
- `Tools/FindSlowTypecheck.swift`.
- 통합 테스트:
  - 워닝이 발생하는 sample 파일에서 finding 수가 양수.
  - threshold가 매우 큰 값일 때 finding 0.
  - 존재하지 않는 파일 → tool result `isError: true` (외부 프로세스 실패).

#### Stage 1.C — `emit_ast`/`emit_sil`/`emit_ir`
- `Toolchain/SwiftcInvocation.swift`: 도구별 인자 빌더의 공통 헬퍼(toolchain resolve + target 인자 구성 + optimization 인자 매핑).
- `Tools/EmitAST.swift`, `Tools/EmitSIL.swift`, `Tools/EmitIR.swift`.
- 통합 테스트: 각 도구가 임시 파일을 만들고 경로+크기 반환. 파일 내용 첫 줄로 형식 sanity check (예: SIL은 `sil_stage canonical` 같은 헤더, IR는 `; ModuleID =`).

#### Stage 1.D — `build_isolated_snippet`
- `Execution/IsolatedRun.swift`: 코드 저장 → 컴파일 → 자식 프로세스 launch + 캡처 + timeout (Process.terminate()) 단위.
- `Tools/BuildIsolatedSnippet.swift`.
- 통합 테스트:
  - 정상 코드: stdout 캡처, exit 0.
  - 컴파일 에러 코드: 빌드 단계 진단 반환, `isError: false` (분석 결과로 본다).
  - 무한 루프(예: `while true {}`): timeout 후 `isError: true`, `timeout: true`.

#### Stage 1.E — Cancellation 매핑 + 정리
- `Server`가 `notifications/cancelled.requestId`를 in-flight handler 추적과 연결.
- `IsolatedRun`이 cancel 신호를 받으면 자식 프로세스에 `SIGTERM`. cancel 도착이 응답 송신 직전이면 best-effort 무시.
- 단위 테스트: `withTaskCancellation` 시나리오에서 자식 프로세스 종료 확인.

### 3.3 검증 도구 (수동 stdio)

각 Stage 1 도구가 도입된 직후 다음을 수동 stdio로 검증한다.

```sh
.build/debug/mcpswx <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"find_slow_typecheck","arguments":{"file":"/tmp/sample.swift","expression_threshold_ms":1,"function_threshold_ms":1}}}
EOF
```

각 응답이 사양 envelope을 따르는지, content에 기대 정보가 들어가는지를 시야로 확인.

### 3.4 Stage 1 안에서 미루는 사항

- progress 노티피케이션 발송 (Stage 2에서 long-running 도구 첫 도입 시 함께).
- AST `text` vs `json` 두 포맷 외의 변형(예: `-dump-scope-maps`).
- 빌드 결과의 sandbox(예: 자식 프로세스 환경변수 제한). Stage 1은 부모 환경 그대로 inherit.
- 산출물의 `resource_link` content type 노출. Stage 1은 `text`에 경로 문자열만.

## 4. Stage 1 종료 후 분기점 (결정: 갈래 A)

Stage 1 종료 시점에 갈래 A(도구 폭 확장, 단일 파일 입력 유지)를 선택. 갈래 B(입력 폭 확장)는 Stage 2 종료 후 진행.

## 5. Stage 2 — 도구 폭 확장 (완료)

Stage 1의 4개 도구에 4개를 추가한다. 인프라 변경은 거의 없고, `SwiftcInvocation` + `CallScratch`/`PersistentScratch` + `WarningParser` 같은 Stage 1 컴포넌트를 재사용한다.

### 5.1 Sub-stages

- **2.A — `compile_stats`** (완료): `swiftc -typecheck -stats-output-dir <dir>`로 frontend stats JSON을 떨군 뒤 카운터를 통합. top-N 카운터 + `byCategory` 합계.
- **2.B — `call_graph`** (완료): SIL을 emit하고 `apply` / `partial_apply` / `witness_method` 등 호출 명령을 파싱하여 caller→callee 그래프 + 동적 디스패치 비율 반환.
- **2.C — `concurrency_audit`** (완료): `-strict-concurrency=<level> -warn-concurrency` 호출 후 진단 라인을 `[#GroupName]` suffix 기준으로 분류. group/severity 별 카운트 + per-finding 위치.
- **2.D — `api_surface`** (완료): `-emit-module -emit-module-path <scratch>/<name>.swiftmodule -emit-symbol-graph -emit-symbol-graph-dir <scratch> -emit-api-descriptor-path <scratch>/api.json -symbol-graph-minimum-access-level <level> -module-name <name> <file>` 호출. 산출물 경로 + 심볼/관계 카운트 + kind 별 집계 반환. PersistentScratch에 모든 빌드 산출물 격리 (cwd 오염 방지).

종료 시점 노출 도구 10개: print_target_info, find_slow_typecheck, emit_ast, emit_sil, emit_ir, build_isolated_snippet, compile_stats, call_graph, concurrency_audit, api_surface. 97 tests / 21 suites 통과.

### 5.2 종료 조건

- `swift build` / `swift test` 통과.
- 위 4개 도구 각각이 단일 파일 입력에 대해 동작하고, sub-stage별 통합 테스트 3건 이상 통과.
- 노출 도구 수 6 → 10.

## 6. Stage 2 종료 후 분기점 (다음: 갈래 B)

갈래 B(입력 폭 확장) 진입 단계. 도구 10개 → 입력 도메인 6단계 중 단일 파일만 가능 → 다음 단계들로 확장:

- **3.A — 소스 디렉토리**: 같은 모듈 가정한 다중 `.swift` 파일. 도구가 `files: [string]` 또는 `directory: string` 입력을 받아 그 안의 모든 파일을 한 swiftc 호출로 처리.
- **3.B — Swift 모듈**: `module-name` + search path 명시. import 해석 가능.
- **3.C — SwiftPM 패키지**: `swift package describe --type json`으로 타깃 정보 추출 → 컴파일러 인자 생성.
- **3.D — Xcode project**: `xcodebuild -showBuildSettings -project ... -target ...` 파싱.
- **3.E — Xcode workspace**: scheme 선택 + workspace level resolution.

각 sub-stage는 새로운 도구 추가가 아니라 **기존 10개 도구의 입력 도메인 확장**. 인자 추출 추상화(`BuildArgsResolver` 같은 인터페이스)를 Stage 3.A 진입 시 도입.

## 5. Stage 2+ (윤곽만)

- 입력 확장: 소스 디렉토리 (같은 모듈 가정) → Swift 모듈 (`-module-name` + search path) → SwiftPM 패키지 (`swift package describe --type json`) → Xcode project (`xcodebuild -showBuildSettings`) → Xcode workspace (scheme 선택).
- 도구 추가: `compile_stats`, `call_graph`, `module_import_diff`, `api_surface`, `api_diff`, `concurrency_audit`, `xcbuild_perf`.
- 격리 실행 고도화: 슬라이싱(`slice_function`) → stub 후보 자동 생성(`extract_with_stubs`) → 빌드 시도 → 누락 심볼 보고 → 클라이언트(LLM) stub 보강 → 재시도 루프.

각 Stage 진입 시 상기 4번의 분기점 결정과 동일한 절차로 PLAN을 갱신한다.

## 6. 비-Stage 정책

다음은 모든 Stage에 적용되는 정책이다.

- **Toolchain 해석 우선순위**: `TOOLCHAINS` env → `xcrun -f swiftc` → `PATH`. 결과 toolchain 경로와 버전을 모든 도구 응답의 메타에 포함.
- **AST/SIL 포맷 비안정성**: 외부에 산출물을 노출할 때 toolchain 버전을 함께 반환. 컴파일러 버전 간 포맷 호환을 약속하지 않는다.
- **호출별 임시 디렉토리**: 두 종류로 분리.
  - `CallScratch` (`$TMPDIR/swiftmcp-<uuid>/`): 호출 처리 동안에만 사용되는 작업 디렉토리. 호출 종료 시 정리(`dispose()` 또는 deinit).
  - `PersistentScratch` (`$TMPDIR/swiftmcp-out-<uuid>/`): 도구 응답으로 *경로*를 노출하는 산출물용. 호출 종료 후에도 보존되어 클라이언트가 파일을 열 수 있음. OS의 임시 디렉토리 정리 정책에 위임.
- **컴파일러 호출 vs 빌드**: 분석 호출(`-typecheck` 등)은 오브젝트 산출 없이 끝나도록 한다. 빌드 캐시 오염 방지.
- **stdio 분리**: 자식 프로세스 stdout/stderr는 부모 stdio와 절대 섞이지 않는다 (Pipe 사용).
- **응답 직렬화**: stdout 쓰기는 actor로 직렬화 — 한 번에 한 줄(JSON + `\n`) 단위로만 atomic.
- **인자 검증**: `swiftc -frontend -emit-supported-arguments`로 받은 토큰 화이트리스트로 동적 검증. 사용자 입력 옵션은 화이트리스트 통과 후 호출.
- **Hidden 옵션 노출 정책**: 본 MCP가 외부에 인자로 노출하는 화이트리스트는 `swiftc --help` 기준. `-help-hidden`/`-frontend -help-hidden`의 옵션은 도구 내부에서만 사용. 사용자가 임의 옵션을 패스하는 채널은 두지 않는다.
- **JSON 키 명명**: 도구 결과의 JSON 키는 Swift property 이름을 그대로 사용한다(camelCase). MCP envelope(`protocolVersion` 등)과 같은 컨벤션을 도구 결과에도 유지하여 한 응답에 두 컨벤션이 섞이지 않게 한다.

## 7. Open Questions

- `build_isolated_snippet`이 Stage 1에서 무엇을 sandbox로 막을지의 구체 목록 (Stage 1.D 진입 시 결정).
- progress 노티피케이션 도입 시점 (Stage 2 long-running 도구 도입 시 검토).
- CLI 진입점(`mcpswx-cli`)의 도입 시점 — Stage 1 종료 후 재검토.
- Stage 6+ 의 "playground/실행 모델 추가"가 본 MCP에 흡수될지, 별도 서버로 분리될지 — Stage 5 종료 후 결정.

## 8. 진행 규칙

- Stage 종료 조건은 검증 명령(빌드·테스트·실행)으로 표현되어야 한다. "거의 다 됐다"는 종료가 아니다.
- Stage 진입 전 PLAN을 읽고, 종료 후 PLAN을 갱신한다.
- 결정 항목을 변경할 때는 본 문서의 해당 절을 새로 쓴 형태로 교체한다 (이력은 git에 둔다).
