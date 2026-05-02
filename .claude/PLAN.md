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

## 6. Stage 2 종료 후 분기점 (갈래 B 완료)

갈래 B(입력 폭 확장) 종료. 입력 도메인 6단계 중 단일 파일만 가능했던 도구 10개가 이제 5가지 입력 케이스 모두 받음:

- **3.A — 소스 디렉토리** ✓ — `BuildInput.file/.directory` + `LocalFilesResolver`.
- **3.B — Swift 모듈** ✓ — `directory.searchPaths`로 외부 모듈 import 해석.
- **3.C — SwiftPM 패키지** ✓ — `BuildInput.swiftPMPackage` + `SwiftPMPackageResolver`.
- **3.D — Xcode project** ✓ — `BuildInput.xcodeProject` + `XcodebuildResolver`.
- **3.E — Xcode workspace** ✓ — `BuildInput.xcodeWorkspace` + 같은 `XcodebuildResolver`(`Mode` enum 분기).

각 sub-stage는 새로운 도구 추가가 아니라 **기존 10개 도구의 입력 도메인 확장**. `BuildArgsResolver` 추상화는 3.A 진입 시 도입 후 그대로 이어졌다.

다음 단계는 §8 (Stage 4+) — 격리 실행 고도화, API diff, workspace build perf. Stage 4 진입 전 §10의 미해결 항목(`build_isolated_snippet` sandbox 정책, progress 노티피케이션 도입 시점, BuildArgs 캐싱 정책 등)을 한 차례 검토.

## 7. Stage 3 — 입력 폭 확장 (갈래 B)

3.A 완료. 113 tests / 24 suites 통과. 새 컴포넌트(`Sources/SwiftcMCPCore/BuildInput/`)와 `BuildInput.file`/`.directory` 케이스가 자리잡았고, 8개 도구(`find_slow_typecheck`, `emit_ast`, `emit_sil`, `emit_ir`, `compile_stats`, `call_graph`, `concurrency_audit`, `api_surface`)의 인자 스키마가 `input` 단일 키로 마이그레이션 완료. `print_target_info`와 `build_isolated_snippet`은 file/directory 입력을 받지 않으므로 변경 없음.

3.B 완료. 115 tests / 25 suites 통과. 3.A의 인프라(`searchPaths` 필드 + `LocalFilesResolver`의 `-I` 매핑 + `SwiftcInvocation`의 search path 적용)가 이미 자리잡혀 있어 코드 변경 없이 fixture(`Tests/Fixtures/Module{A,B}/`)와 통합 테스트만 추가. ModuleA는 각 테스트에서 `CallScratch`에 `swiftc -emit-module -parse-as-library`로 즉시 빌드(빌드 산출물은 git에 commit 안 함). 양성 케이스(searchPaths 지정 → import 해석 성공) + 음성 케이스(searchPaths 누락 → `error: no such module 'ModuleA'`)로 search path가 실제 효과를 가진다는 결정적 증거 확보.

3.C 완료. 127 tests / 27 suites 통과. `BuildInput.swiftPMPackage` 케이스 + `SwiftPMPackageResolver` 추가. resolver는 `swift package --package-path X describe --type json`으로 타깃 메타를 추출하고, 선택된 타깃이 internal `target_dependencies`를 가지면 `PersistentScratch`에 `swift build --package-path X --scratch-path Y`로 사전 빌드 후 `--show-bin-path`로 얻은 `<bin>/Modules`를 search path로 노출. 외부 패키지 의존성은 후속(§7.7).

3.D 완료. 141 tests / 30 suites 통과. `BuildInput.xcodeProject` 케이스 + `XcodebuildResolver` 추가. resolver는 `xcodebuild build`를 `PersistentScratch`(`OBJROOT`/`SYMROOT` 격리)에 한 번 실행하고, 후속 `xcodebuild -showBuildSettings`로 `SWIFT_RESPONSE_FILE_PATH_normal_<host>`가 가리키는 SwiftFileList를 읽어 입력 파일을 얻는다. 빌드 오버라이드는 `GENERATE_INFOPLIST_FILE=YES CODE_SIGNING_ALLOWED=NO ARCHS=<host>`. 모듈명은 `PRODUCT_MODULE_NAME ?? PRODUCT_NAME ?? TARGET_NAME` 우선순위. `extraSwiftcArgs`로 `-sdk <SDKROOT>`와 정규화된 `-swift-version` 전달.

**채널 매핑 정정 (Codex stop-time review 지적 반영)**: `xcodebuild build`의 비-제로 exit code는 무시한다. 대상 타깃의 Swift 코드 컴파일 에러는 PLAN §0.3에 따라 *분석 산출물*이지 tool 에러가 아니다. 빌드가 컴파일 단계에서 실패해도 swift 빌드 시스템은 SwiftFileList를 사전에 머터리얼라이즈하므로(probe로 확인), resolver는 launch failure만 throw하고 진행. SwiftFileList 자체 부재 시에만 `toolExecutionFailed`. 이를 검증하기 위해 `Tests/Fixtures/BrokenProject.xcodeproj`(고의 type mismatch) fixture와 `compileStatsSurfacesCompilerErrorAsDiagnostic` 테스트 추가.

Fixture(`Tests/Fixtures/SampleProject.xcodeproj`, `Tests/Fixtures/BrokenProject.xcodeproj`)는 손으로 작성한 minimal pbxproj(static library 타깃, Info.plist 불필요). `.build/`는 이미 전역 gitignore.

3.E 완료. 155 tests / 32 suites 통과. Stage 3 (갈래 B) 종료. `BuildInput.xcodeWorkspace` 케이스 + `XcodebuildResolver`에 workspace 모드 추가. 코어 흐름(빌드 → showBuildSettings → SwiftFileList)은 100% 재사용; 인자 구성만 `Mode` enum으로 분기하여 `-project X -target Y` 또는 `-workspace X -scheme Y` 노출. fixture는 `Tests/Fixtures/SampleWorkspace.xcworkspace/contents.xcworkspacedata` 단일 XML 파일이 3.D의 SampleProject를 참조 — 별도 `.xcscheme` XML 불필요(참조 project의 auto-generated scheme이 노출된다는 probe 결과).

**Codex stop-time review 두 번째 지적 반영 (target ambiguity)**: workspace + multi-buildable scheme(여러 BuildableReference를 가진 명시 scheme XML)에서 `xcodebuild -showBuildSettings`가 타깃별 settings 블록을 차례로 출력. 단순 덮어쓰기 파서는 *마지막* 블록의 SwiftFileList를 반환해 임의의 잘못된 타깃을 분석할 위험. 수정: (1) 파서를 target-aware로 변경 — 헤더 `Build settings for action … and target X:`로 블록 분리, `Build settings from command line:` 에코는 폐기 블록으로 분류. (2) `BuildInput.xcodeWorkspace`에 옵셔널 `targetName` 추가. (3) `chooseSettingsBlock`: 1 블록 → 사용, N 블록 + targetName 명시 → 매치, N 블록 + 미명시 → `invalidParams`로 명시 요청. (4) fixture `Tests/Fixtures/MultiBuildableProject.xcodeproj/xcshareddata/xcschemes/All.xcscheme`(Lib + App 둘 다 빌드)와 `Tests/Fixtures/MultiBuildableWorkspace.xcworkspace`. (5) `SettingsBlock` 단위 테스트 + multi-buildable scheme 통합 3건 (refuse-without-name, select-by-name, reject-unknown).

**Codex stop-time review 세 번째 지적 반영 (single-target silent miss)**: `chooseSettingsBlock`의 단일 블록 fast-path가 명시된 `target_name`을 검증 없이 통과시켜 잘못된 이름이 silent하게 무시됨. 사용자가 `target_name: "Foo"`를 줬는데 워크스페이스 scheme이 실제로 `Bar`만 빌드하면, resolver가 `Bar`의 SwiftFileList를 반환하면서 사용자는 `Foo`를 분석했다고 잘못 가정. 수정: 단일 블록도 explicit target_name과 블록의 `TARGET_NAME` 일치 검증, 불일치 시 `invalidParams`로 throw. 단위 테스트에 single-target mismatch 케이스 + 통합 테스트 2건 추가 (`singleTargetWorkspaceRejectsMismatchedTargetName`, `singleTargetWorkspaceAcceptsMatchingTargetName`).

부수적 수정 (실제 race condition 발견·수정): Stage 3.D/E의 병렬 xcodebuild 부하가 `BuildIsolatedSnippet cancellation` 테스트를 60초 wall-clock 타임아웃까지 대기하게 만들면서, `PIDHolder`의 race를 노출시켰다. 부하 시 `Task.detached`가 스케줄되기 전에 parent의 `task.cancel()`이 도달하면 `withTaskCancellationHandler.onCancel`이 `holder.get() == 0`을 보고 SIGTERM을 어디로도 보내지 못해 자식 프로세스가 자연 종료까지 60초를 대기하는 문제. 수정: `PIDHolder`에 sticky `cancelled` 플래그 + `markCancelled()` 메서드 추가. cancel이 set() 전에 도착해도 sticky flag가 기억되고, 다음 `set(pid)`가 즉시 SIGTERM을 보낸다. `onCancel`은 `markCancelled()`를 호출. 이로써 race window가 사라지고 cancellation 테스트의 5초 elapsed threshold가 부하 하에서도 안정적으로 통과.

3.A/B/C/D 진행 중 학습된 사항 (PLAN 또는 CLAUDE.md에 정책으로 흡수할 후보):

- **`-o` + 다중 입력 파일**: swiftc는 `-emit-sil`/`-emit-ir`/`-emit-bc`에 대해 `-wmo`가 있으면 단일 출력 파일을 받지만, `-wmo` 없이는 "cannot specify -o when generating multiple output files"로 거부한다. `SwiftcInvocation.run`이 `outputFile` + `inputFiles.count > 1` 조건에서 `-wmo`를 자동 주입 — 도구가 신경 쓸 필요 없음.
- **`-dump-ast` 다중 입력 파일**: swiftc는 `-dump-ast`와 함께 사용된 `-wmo`를 무시한다 (`warning: ignoring '-wmo' because '-dump-ast' was also specified`). `EmitAST`는 다중 파일 케이스에서 `-o`를 떼고 stderr로 받은 AST를 직접 scratch 파일에 기록하는 방식으로 우회. 단일 파일 경로는 기존처럼 `-o` 사용.
- **시스템 경계 검증 위치**: 입력 파일 존재 여부 검증은 `LocalFilesResolver`로 끌어올림 (이전 도구 구현은 swiftc 종료 코드를 통해 사후 신호). "missing file" 케이스는 이제 `MCPError.invalidParams`로 throw → JSON-RPC error로 흘러간다 (Global Rule #2의 시스템 경계 검증 원칙).
- **resolver의 module name 추정**: `.directory` case에서 `moduleName` 미지정 시 디렉토리 basename을 sanitize해 사용. `api_surface`는 자체 override 채널을 유지(top-level `module_name` 인자가 우선).
- **`swift package describe`의 인자 위치 비대칭**: `--package-path`는 `swift build --package-path X` 형태(서브커맨드 뒤)는 허용하지만, `swift package describe --package-path X`는 거절(`Unknown option`). `swift package` 서브커맨드 호출 시 글로벌 옵션은 반드시 `swift package --package-path X --scratch-path Y describe …` 순서로 서브커맨드 앞에 배치한다. `swift build`는 어느 위치든 동작.
- **`swift build --target` 다중 지정 미동작**: `--target A --target B`는 마지막 `--target B`만 적용된다. 의존 타깃 다수가 있을 때는 `--target` 없이 전체 빌드(`swift build --package-path X --scratch-path Y`)로 폴백.
- **`--show-bin-path`**: 실제 빌드 없이 `<scratch>/<triple>/<config>` 경로를 즉시 출력. 빌드 산출물 위치를 deterministic하게 얻는 데 유용 (트리플 추정 불필요).
- **`xcodebuild -dry-run` 제거**: Xcode 26은 `-dry-run` 옵션을 거절(`option '-dry-run' is no longer supported`). 컴파일 명령을 사전 캡처하는 길은 막혀 있음. 입력 파일 추출은 실제 빌드 후 SwiftFileList 읽기로만 가능.
- **`xcodebuild build` 오버라이드 패턴**: `GENERATE_INFOPLIST_FILE=YES CODE_SIGNING_ALLOWED=NO ARCHS=<host> OBJROOT=X SYMROOT=Y`로 framework 타깃 코드사인/Info.plist 요구를 우회하면서 빌드 산출물을 격리 디렉토리에 둘 수 있음. `-derivedDataPath`는 `-scheme` 강제라 사용 불가(`xcodebuild: error: The flag -scheme … is required`).
- **`SWIFT_RESPONSE_FILE_PATH_normal_<arch>`**: 빌드 후 이 경로의 파일에 swiftc가 컴파일할 입력 파일이 한 줄에 한 개씩 절대 경로로 기록됨. xcodebuild가 분석 도구에 노출하는 정식 채널.
- **`SWIFT_VERSION` 정규화**: Xcode가 `SWIFT_VERSION = 6.0` 형태로 보고하지만 swiftc는 `-swift-version 6.0`을 거절(`note: valid arguments to '-swift-version' are '4', '4.2', '5', '6'`). 후행 `.0`을 제거해야 함.
- **build settings KEY 문자 집합**: `KEY = VALUE` 형식이지만 키에는 소문자가 섞일 수 있음(예: `SWIFT_RESPONSE_FILE_PATH_normal_arm64`). 파서는 영숫자+언더스코어를 모두 허용해야 함.
- **xcodebuild 빌드 실패와 SwiftFileList의 분리**: 사용자 코드 컴파일 에러로 `xcodebuild build`가 비-제로 exit code를 내도 SwiftFileList는 swiftc 컴파일 단계 *전에* 빌드 시스템이 머터리얼라이즈한다 — probe로 확인. 따라서 resolver는 build의 exit code를 분석 결과의 신호로 삼지 않으며, launch failure만 toolExecutionFailed로 격상한다. PLAN §0.3 채널 매핑(컴파일 진단 = 분석 산출물)과 일치하는 동작.
- **workspace의 auto-generated scheme**: `.xcworkspace`에 `xcshareddata/xcschemes/<Name>.xcscheme`이 commit되어 있지 않아도, 참조된 project의 default target(들)이 scheme으로 자동 노출된다(probe로 확인). fixture가 `contents.xcworkspacedata` 1개 파일로 충분한 이유.
- **xcodebuild -showBuildSettings 헤더 두 종류**: `Build settings from command line:`(우리가 넘긴 KEY=VALUE 오버라이드 echo) + `Build settings for action <action> and target <name>:`(타깃 settings). 후자만 분석 대상. command-line echo를 잘못 분류하면 단일-타깃 호출이 multi-target처럼 보여 ambiguity 오류 발생 — 파서가 두 헤더를 모두 인식하고 echo 블록은 결과에서 제외해야 함.
- **multi-buildable scheme의 target ambiguity**: `xcshareddata/xcschemes/<Name>.xcscheme`에 여러 `BuildableReference`가 있으면 `-scheme X -showBuildSettings`가 타깃별 블록을 차례로 출력. resolver는 1 블록일 때 그대로 사용, N 블록이면 명시적 `target_name` 요구. 자동 선택 시도(첫 블록/마지막 블록)는 임의적이라 회피.
- **단일 블록도 명시 타깃은 검증해야 한다**: `chooseSettingsBlock`이 1 블록 fast-path에서 explicit `target_name`을 묵살하면, 사용자가 잘못된 이름을 줬을 때 silent하게 다른 타깃의 결과가 반환됨. 1 블록일 때도 명시 이름과 블록의 `TARGET_NAME`을 비교해 불일치 시 `invalidParams` throw가 필요. (Codex stop-time review 지적)

#### 7.3.D — Xcode project 학습 사항 (체크리스트 form)
- xcodebuild → SwiftFileList 채널 외 다른 입력 추출 경로는 Xcode 26에서 막힘 (`-dry-run` 제거, pbxproj 자체 파싱은 PLAN 정책상 회피).
- 빌드 산출물 격리는 `OBJROOT`/`SYMROOT` 오버라이드로 (`-derivedDataPath`는 `-scheme` 강제).
- framework/app 타깃 빌드는 `GENERATE_INFOPLIST_FILE=YES CODE_SIGNING_ALLOWED=NO`로 Info.plist/codesign 의존을 우회.



10개 도구의 입력 도메인을 단일 파일에서 다음 단계까지 확장한다 — **새 도구는 추가하지 않는다.**

```
단일 파일 → 소스 디렉토리 → Swift 모듈 → SwiftPM 패키지 → Xcode project → Xcode workspace
```

확장 후에도 단일 파일 입력은 계속 동작 (지원 입력의 superset).

### 7.1 입력 schema 통일 (Breaking change)

기존: 도구마다 `file: string`. Stage 3 이후: `input` 단일 키 — discriminated union.

```jsonc
"input": { "file": "/abs/path/file.swift", "target": "arm64-apple-macos14" }
"input": { "directory": "/abs/path/sources", "module_name": "MyLib", "target": "..." }
"input": { "directory": "/abs/path/B", "module_name": "B", "search_paths": ["/abs/path/A_built"] }
"input": { "package": "/abs/path/PackageDir", "target_name": "MyLib", "configuration": "debug" }
"input": { "project": "/abs/path/X.xcodeproj", "target_name": "MyApp", "configuration": "Debug" }
"input": { "workspace": "/abs/path/X.xcworkspace", "scheme": "MyApp", "configuration": "Debug" }
```

규칙:
- `file` / `directory` / `package` / `project` / `workspace` 중 정확히 하나가 필수.
- 둘 이상 동시 지정 시 `MCPError.invalidParams`.
- `target` / `target_name` / `configuration` / `module_name` / `search_paths`는 케이스별 옵셔널.
- 모든 도구가 같은 `input` schema를 받는다 — `build_isolated_snippet`은 예외 (소스 문자열을 인자로 받음, 파일 시스템 입력 없음).

본 0.x 단계라 외부 사용자가 적어 한 번에 마이그레이션. 각 통합 테스트가 새 schema로 변경된다.

### 7.2 인프라 추가

새 모듈: `Sources/SwiftcMCPCore/BuildInput/`

- **`BuildInput.swift`** — `enum BuildInput: Sendable, Codable, Equatable`. 5개 case (`file`, `directory`, `swiftPMPackage`, `xcodeProject`, `xcodeWorkspace`). `directory` case는 `searchPaths: [String]`을 옵셔널로 가짐 (3.B에서 사용).
- **`BuildArgsResolver.swift`** — `protocol BuildArgsResolver: Sendable`. 한 메서드 `resolveArgs(for: BuildInput) async throws -> ResolvedBuildArgs`.
- **`ResolvedBuildArgs.swift`** — `struct { inputFiles: [String], moduleName: String?, target: String?, searchPaths: [String], frameworkSearchPaths: [String], extraSwiftcArgs: [String] }`.
- 단계별 resolver 구현체:
  - `LocalFilesResolver` (3.A — `file`/`directory`).
  - `SwiftPMPackageResolver` (3.C).
  - `XcodebuildResolver` (3.D, 3.E — project/workspace 공통).

`BuildArgsResolver`는 dispatcher 패턴 — 입력 case에 따라 적절한 resolver로 위임. 내부적으로 한 actor가 모든 resolver를 보유.

기존 컴포넌트 변경:
- **`SwiftcInvocation`**: `inputFile: String` → `inputFiles: [String]` (다중 파일). `searchPaths`/`frameworkSearchPaths`/`extraSwiftcArgs`도 인자로 받아 `-I`/`-F`/추가 플래그로 전달.
- 모든 10개 도구의 `call(arguments:)`: `BuildInput` 디코드 → `resolver.resolveArgs(for:)` → `SwiftcInvocation` 호출. 변경량은 도구당 ~10줄.

### 7.3 Sub-stages

#### 7.3.A — 소스 디렉토리 (완료)

목표 충족: `file` + `directory` 입력 지원. 다중 파일 한 swiftc 호출.

수행 작업:
1. ✓ `Sources/SwiftcMCPCore/BuildInput/BuildInput.swift` (`file` + `directory` 케이스 + JSON schema fragment).
2. ✓ `BuildArgsResolver` 프로토콜 + `DefaultBuildArgsResolver` dispatcher + `LocalFilesResolver` 구현체. directory case는 top-level `*.swift` 글롭, moduleName 자동 추정(basename sanitize).
3. ✓ `SwiftcInvocation`: `inputFile: String` → `inputFiles: [String]`, `searchPaths`/`frameworkSearchPaths`/`extraSwiftcArgs` 인자 + `-wmo` 자동 주입(다중 입력 + `-o` 케이스).
4. ✓ 8개 도구 마이그레이션 (`print_target_info`/`build_isolated_snippet`은 입력 비대상). `EmitAST`는 다중 파일 + `-dump-ast` 조합에서 `-o`를 떼고 stderr 캡처 후 직접 기록.
5. ✓ 8개 통합 테스트 파일 `input` schema로 마이그레이션. "missing file" 시나리오는 resolver throw로 의미가 바뀌어 테스트도 그에 맞게 변경.
6. ✓ 새 통합 테스트 (`BuildInputTests.swift`): `Tests/Fixtures/MultiFileSources/{A.swift,B.swift}`에 대해 `emit_ast`/`compile_stats`/`api_surface`가 두 파일의 선언을 모두 처리. 단위 테스트로 `BuildInput.decode` 7건 + `LocalFilesResolver` 6건.

종료 조건:
- ✓ `swift build` 통과.
- ✓ `swift test` 113 tests / 24 suites 통과 (sync, no `--parallel`).
- ✓ 단일 파일 입력 + 디렉토리 입력 둘 다 동작.

#### 7.3.B — Swift 모듈 (search paths) (완료)

목표 충족: `directory` 케이스의 `search_paths`가 외부 모듈 import 해석에 동작.

수행 작업:
1. ✓ `BuildInput.directory`의 `searchPaths: [String]` 필드는 3.A에서 이미 도입되어 있어 변경 없음. 비어 있으면 `-I` 인자 미발생, 채워지면 절대화 후 전달.
2. ✓ `LocalFilesResolver`가 `-I <path>` 매핑은 3.A에서 이미 처리. 변경 없음.
3. ✓ Fixture: `Tests/Fixtures/ModuleA/A.swift`(public 선언) + `Tests/Fixtures/ModuleB/B.swift`(`import ModuleA`).
4. ✓ 통합 테스트(`ModuleSearchPathTests.swift`):
   - 양성: 테스트가 `CallScratch`에 `swiftc -emit-module -emit-module-path … -module-name ModuleA -parse-as-library`로 ModuleA 사전 빌드 → `compile_stats`가 `searchPaths: [<scratch>]`로 ModuleB type-check, `compilerExitCode == 0` + stderr에 'no such module' 없음.
   - 음성: `searchPaths` 누락 시 `compilerExitCode != 0` + stderr에 `no such module 'ModuleA'` 포함.

종료 조건:
- ✓ 다른 모듈을 import하는 코드의 type-check 성공 (양성).
- ✓ search path 누락 시 import 실패가 진단으로 표면화 (음성).
- ✓ `swift test` 115 tests / 25 suites 통과 (sync, no `--parallel`).

#### 7.3.C — SwiftPM 패키지 (완료)

목표 충족: `package` 입력. 패키지 매니페스트 + 타깃 이름으로 자동 인자 구성.

수행 작업:
1. ✓ `BuildInput.swiftPMPackage(path, targetName?, configuration?, target?)` 추가. `decode`가 `package`/`target_name`/`configuration`/`target` 키 인식. `jsonSchemaProperty` 갱신.
2. ✓ `SwiftPMPackageResolver` 신규 (`Sources/SwiftcMCPCore/BuildInput/SwiftPMPackageResolver.swift`):
   - `swift package --package-path <abs> describe --type json` 호출 (cwd-neutral).
   - JSON 파싱(`PackageDescription`/`Target` Decodable). `module_type == "SwiftTarget"` 필터.
   - 타깃 선택: `targetName` 지정 시 정확히 일치, 미지정 시 첫 `type == "library"` SwiftTarget.
   - 입력 파일: `<package.path>/<target.path>/<source>` 절대 경로.
   - `target_dependencies` 비어있지 않으면 `PersistentScratch`에 `swift build --package-path X --scratch-path Y --configuration <cfg>`로 전체 사전 빌드 후 `--show-bin-path`로 `<bin>/Modules` 획득 → `searchPaths`.
   - swift 바이너리 경로는 `swiftcPath`의 디렉토리에서 `swift`로 파생.
3. ✓ `DefaultBuildArgsResolver`에 `.swiftPMPackage` 분기 추가. `LocalFilesResolver`는 `.swiftPMPackage`를 받으면 `internalError` throw (라우팅 위반 보호).
4. ✓ Fixture: `Tests/Fixtures/SamplePackage/` (Lib 단일 타깃) + `Tests/Fixtures/MultiTargetPackage/` (Core + App, App이 Core 의존).
5. ✓ 테스트: `BuildInput swiftPMPackage decoding` 단위 5건 + `SwiftPMPackageResolver (integration)` 7건. 양성/음성/end-to-end(compile_stats) 모두 커버.

종료 조건:
- ✓ 라이브러리 타깃 1개의 패키지가 동작 (SamplePackage).
- ✓ 내부 `target_dependencies`가 있는 패키지가 동작 (MultiTargetPackage + App).
- ✓ `swift test` 127 tests / 27 suites 통과 (sync, no `--parallel`).

미루는 사항: 외부 패키지 의존(예: swift-collections)의 `Package.resolved`/`.build/checkouts/` 활용 — 3.D 진입 전후로 재검토.

#### 7.3.D — Xcode project (완료)

목표 충족: `project` 입력. `xcodebuild build` + `xcodebuild -showBuildSettings`로 인자 구성.

수행 작업:
1. ✓ `BuildInput.xcodeProject(path, targetName, configuration?, target?)` 추가. `decode`가 `project`/`target_name`/`configuration`/`target` 키 인식. `target_name`은 필수. `jsonSchemaProperty` 갱신.
2. ✓ `XcodebuildResolver` 신규 (`Sources/SwiftcMCPCore/BuildInput/XcodebuildResolver.swift`):
   - `.xcodeproj` 디렉토리 + `project.pbxproj` 존재 검증.
   - `PersistentScratch`(`obj/`, `sym/` 하위)에 `xcodebuild build -project X -target T -configuration C GENERATE_INFOPLIST_FILE=YES CODE_SIGNING_ALLOWED=NO ARCHS=<host> OBJROOT=… SYMROOT=…` 실행.
   - 같은 오버라이드로 `xcodebuild -showBuildSettings` 호출 → `KEY = VALUE` 줄 파싱.
   - `SWIFT_RESPONSE_FILE_PATH_normal_<host>`가 가리키는 SwiftFileList 파일을 읽어 절대 경로 입력 파일 리스트 획득.
   - moduleName: `PRODUCT_MODULE_NAME ?? PRODUCT_NAME ?? TARGET_NAME`.
   - `extraSwiftcArgs`: `-sdk <SDKROOT>`, 정규화된 `-swift-version` (후행 `.0` 제거).
3. ✓ `DefaultBuildArgsResolver`에 `.xcodeProject` 분기 추가. `LocalFilesResolver`는 잘못 라우팅 시 `internalError`.
4. ✓ Fixture: `Tests/Fixtures/SampleProject.xcodeproj/project.pbxproj` (손으로 작성한 minimal pbxproj, static library `Sample` 타깃) + `Tests/Fixtures/SampleProject/Sources/Sample.swift`.
5. ✓ 테스트: `BuildInput xcodeProject decoding` 단위 5건 + `XcodebuildResolver unit`(파서·정규화) 3건 + `XcodebuildResolver (integration)` 6건 (resolver, 미존재 target, 비-`.xcodeproj`, compile_stats e2e, 컴파일-에러-있는-타깃 resolver 진행, 컴파일-에러를 진단으로 노출하는 e2e).
6. ✓ Codex stop-time review 지적 반영: build 실패를 tool 에러로 처리하지 않도록 resolver 수정 + BrokenProject fixture + 컴파일 에러 채널 검증 테스트 2건 추가.

종료 조건:
- ✓ 1 타깃 프로젝트의 단순 분석이 동작 (SampleProject `Sample` 타깃에 대해 compile_stats가 `compilerExitCode == 0` 반환).
- ✓ 타깃 코드에 컴파일 에러가 있어도 분석 도구가 진단을 회수 (BrokenProject `Broken` 타깃에 대해 compile_stats가 `isError == false` + `compilerExitCode != 0` + stderr에 `error:` 포함).
- ✓ `swift test` 141 tests / 30 suites 통과 (sync, no `--parallel`).

미루는 사항: Build Phases 자체 파싱은 안 함 — xcodebuild + SwiftFileList 채널만 사용. `SWIFT_INCLUDE_PATHS`/`FRAMEWORK_SEARCH_PATHS`/`OTHER_SWIFT_FLAGS` 등 추가 settings 통과는 후속 단계에서 필요 시 도입.

#### 7.3.E — Xcode workspace (완료)

목표 충족: `workspace` 입력. `-workspace` + `-scheme`.

수행 작업:
1. ✓ `BuildInput.xcodeWorkspace(path, scheme, configuration?, target?)` 추가. `decode`가 `workspace`/`scheme` 키 인식. `scheme`은 필수. `jsonSchemaProperty` 갱신.
2. ✓ `XcodebuildResolver` 확장: 내부 `Mode` enum(`project`/`workspace`)으로 인자 구성 분기. 코어 흐름(빌드 → showBuildSettings → SwiftFileList → ResolvedBuildArgs 조립)은 100% 재사용.
3. ✓ Fixture: `Tests/Fixtures/SampleWorkspace.xcworkspace/contents.xcworkspacedata` (15줄 XML, 3.D의 `SampleProject.xcodeproj` 참조). 별도 `.xcscheme` XML 불필요 — 참조 project의 default target이 auto-generated scheme으로 노출됨(probe로 확인).
4. ✓ `DefaultBuildArgsResolver`에 `.xcodeWorkspace` 분기 추가(같은 dispatch case로 묶음). `LocalFilesResolver`는 잘못 라우팅 시 `internalError`.
5. ✓ 테스트: `BuildInput xcodeWorkspace decoding` 단위 5건 + `XcodebuildResolver workspace mode (integration)` 4건 (resolver, 미존재 scheme, 비-`.xcworkspace`, compile_stats e2e).
6. ✓ 부수 수정 (실제 race condition 수정): `PIDHolder`에 sticky cancel flag + `markCancelled()` 메서드 추가. `onCancel`이 `Task.detached`의 `holder.set(pid)`보다 빨리 도달해도 SIGTERM이 손실되지 않도록 보강. `taskCancellationTerminatesChildProcess` 테스트의 elapsed threshold는 5초로 유지 (병렬 xcodebuild 부하 하에서도 안정 통과).

종료 조건:
- ✓ workspace + scheme 단순 케이스 동작 (SampleWorkspace의 `Sample` scheme에 대해 compile_stats가 `compilerExitCode == 0` 반환).
- ✓ multi-buildable scheme(`MultiBuildableProject`의 `All` scheme이 Lib + App 둘 다 빌드)에 대해 `target_name` 미지정 시 `invalidParams` throw, 명시 시 정확한 타깃의 SwiftFileList 반환.
- ✓ 단일 타깃 워크스페이스에 잘못된 `target_name` 명시 시 `invalidParams` throw (silent miss 방지).
- ✓ `swift test` 157 tests / 32 suites 통과 (sync, no `--parallel`).

### 7.4 sub-stage별 종료 조건 공통

각 sub-stage:
- `swift build` 통과.
- 새 input case에 대한 단위 테스트 (resolver) + 통합 테스트 (실제 도구 호출) 통과.
- 기존 통합 테스트가 새 schema로 마이그레이션되어 통과.
- `swift test` 전체 회귀 통과 (sync, never `--parallel` — macOS 26 deadlock).

### 7.5 검증 fixture 정책

`Tests/Fixtures/`에 commit:
- `MultiFileSources/A.swift`, `B.swift` (3.A).
- `ModuleA/A.swift`, `ModuleB/B.swift` (3.B). ModuleA의 빌드 산출물은 테스트에서 동적 생성 (commit 안 함, scratch에).
- `SamplePackage/Package.swift`, `SamplePackage/Sources/Lib/Lib.swift` (3.C).
- `SampleProject.xcodeproj/project.pbxproj` + Sources (3.D).
- `SampleWorkspace.xcworkspace/contents.xcworkspacedata` (3.E).

### 7.6 비-Stage 정책 영향

- swiftc 호출은 항상 cwd-neutral. emit-module 류 옵션은 명시적 출력 경로(`-emit-module-path` 등) 필요. Stage 2.D에서 학습된 사고 (`LibProbe` 부산물 cwd 누설). Resolver는 cwd를 변경하지 않고, 입력 파일은 절대 경로로 정규화한다.
- `BuildArgsResolver` 결과 캐시 가능 (toolchain version + input hash 키). 도입 시점은 Stage 3 종료 후 검토.

### 7.7 미루는 사항

- 외부 의존 있는 SwiftPM 패키지 (3.C 종료 후).
- Tuist 같은 third-party 빌드 시스템 통합 (현재 범위 외).
- xcconfig 파일 직접 파싱 (xcodebuild가 처리).
- BuildArgs 캐싱 정책.

## 8. Stage 4+ (윤곽 + 1차 진행)

### Stage 4-1 (완료) — 격리 실행 고도화: 누락 심볼 보고 + Stub 제안

182 tests / 36 suites 통과. PLAN §8 격리 실행 루프의 5단계(슬라이싱 → stub 후보 자동 생성 → 빌드 시도 → 누락 심볼 보고 → 클라이언트 stub 보강 → 재시도) 중 *누락 심볼 보고 + stub 시작점 제안* 두 단계만 도구로 노출. 슬라이싱은 swift-syntax 없는 텍스트 AST 슬라이싱이 fragile해 후속(Stage 4-2)으로 이연.

수행 작업:
1. ✓ `Diagnostics/MissingSymbol.swift` — `MissingSymbol`(name/kind/locations/usagePattern/falsePositive) + `MissingSymbolClassifier`. 진단 메시지 정규식 4개(`cannot find '<x>' in scope`, `cannot find type '<x>' in scope`, `no such module '<x>'`, legacy `use of unresolved identifier '<x>'`).
2. ✓ `Diagnostics/ASTIdentifierExtractor.swift` — `swiftc -dump-ast` stdout에서 declared identifier `Set<String>` 추출. 9개 정규식(parameter / pattern_named / func_decl 베이스 / struct_decl / class_decl / enum_decl / protocol_decl / typealias_decl / import_decl).
3. ✓ `Tools/ReportMissingSymbols.swift` — `swiftc -typecheck` + `swiftc -dump-ast` 병렬 호출 → 분류 + AST cross-check. `kind == .module`은 cross-check 면제 (import_decl이 unresolved 모듈에도 declared로 잡혀 false positive 마스킹 위험).
4. ✓ `Tools/SuggestStubs.swift` — usagePattern별 휴리스틱(call → `func X(_ a0: Any, _ a1: Any) -> Any { fatalError() }` 인자 개수 추론, type → `struct X { public init() {} }`, member → `var X: Any`, 그 외 → `let X: Any`). `missing_symbols` 인자 미제공 시 자체 typecheck 실행.
5. ✓ Mcpswx에 두 도구 등록 (12 → 12 도구로 변경 — 새 2개 추가, 합 12 도구). 정정: 8개 분석 도구 + `print_target_info`/`build_isolated_snippet` + `report_missing_symbols`/`suggest_stubs` = 12.
6. ✓ 단위 테스트 16건(MissingSymbolClassifier 9 + ASTIdentifierExtractor 7) + 통합 11건(ReportMissingSymbols 4 + SuggestStubs 7, e2e report→suggest→build 1건 + falsePositive skipped 검증 2건 포함).

학습 사항:
- **`-dump-ast` 출력 채널**: AST는 stdout, 진단은 stderr. probe 초기에 `2>&1`로 합쳐 보다가 stderr에서 AST를 읽도록 잘못 구현했다가 단위/통합 테스트가 잡아냈음.
- **`import_decl`은 declaration이지만 resolution이 아님**: 모듈을 못 찾아도 `(import_decl module="X")` 노드는 emit. AST cross-check를 module kind에 적용하면 unresolved 모듈을 false positive로 마스킹 → classifier에서 module kind에는 cross-check 면제.
- **AST 텍스트 정규식의 안정성**: 핵심 노드(parameter/pattern_named/func_decl/struct_decl/class_decl/enum_decl/protocol_decl/typealias_decl/import_decl)는 Swift 6.x 내내 안정적. toolchain 업그레이드 시 sample AST 텍스트로 회귀 모니터링.
- **falsePositive 처리는 두 진입점 모두에서 일관되게**: `suggest_stubs`가 외부에서 받은 `missing_symbols`와 자체 도출한 리스트 두 경로 모두 falsePositive를 *skipped*로 분류해야 한다 (Codex stop-time review 지적). 외부 리스트만 그대로 통과시키면, 사용자가 `report_missing_symbols` 출력을 그대로 넘겼을 때 false-positive 마킹이 무시되어 잘못된 stub이 만들어진다. `StubBuilder.buildStubs`가 falsePositive 분기를 가장 먼저 처리.

### Stage 4-2 (완료) — 격리 실행 고도화: `slice_function`

213 tests / 41 suites 통과. 단일 Swift 파일에서 함수 1개와 transitively 의존하는 top-level 정의만 추출해 self-contained 슬라이스로 반환하는 도구. PLAN §8 격리 실행 루프 5단계 중 *슬라이싱* 단계 도입.

수행 작업:
1. ✓ `Slicing/SourceRangeMapper.swift` — 1-based UTF-8 byte (line, column) → `String.Index` 변환. multibyte 안전. line 단위 substring 헬퍼는 attribute(`public`/`@…`) 보존을 위해 startLine 시작 ~ endLine 끝까지 통째 자른다.
2. ✓ `Slicing/DeclIndex.swift` — AST 텍스트의 top-level decl을 색인. 들여쓰기 깊이(`  (` 2-space prefix)로 source_file 직속 노드만 추출. 8개 decl_kind 정규식 (func/struct/class/enum/protocol/typealias/extension/var). overload 다중 매치 지원.
3. ✓ `Slicing/ReferenceCollector.swift` — decl range 안의 `(declref_expr|member_ref_expr|… decl="<chain>@file:line:col" …)`와 `(type_unqualified_ident id="X" …)`에서 외부 참조 이름 수집. 참조 site의 *선언 site*가 enclosing range 안이면 로컬 바인딩으로 분류해 제외 (parameter, let, inner func). range= 없는 라인은 직전 anchor의 부모 노드로 attribute.
4. ✓ `Slicing/DependencyGraph.swift` — BFS transitive closure. `DeclIndex.find(name:)`로 매치되지 않는 이름은 `externalReferences`로. 사이클 회피, 오버로드는 모든 시그니처 포함.
5. ✓ `Tools/SliceFunction.swift` — 입력 `BuildInput.file` + `function_name`. 동작: `swiftc -dump-ast` → DeclIndex → start entry 선택(overload는 signature_key 명시 강제) → BFS closure → SourceRangeMapper로 라인 단위 슬라이스 → import 라인 보존 → 자체 검증(`swiftc -typecheck` + `MissingSymbolClassifier`로 unresolvedReferences 분류).
6. ✓ Mcpswx에 도구 등록 (총 13 도구).
7. ✓ Fixture: `Tests/Fixtures/SliceTargets/Library.swift` — Counter struct + describe/formatLabel(의존) + unrelated(독립) + helper overload + useHelper 1 파일에 모두.
8. ✓ 테스트:
   - 단위: SourceRangeMapper 6 + DeclIndex 7 + ReferenceCollector 5 + DependencyGraph 5 = 23.
   - 통합: SliceFunction 6 (struct 의존, self-typecheck, missing function, ambiguous overload, signature_key disambiguation, slice → suggest_stubs → build e2e).

학습 사항:
- **range= 시작 column은 *이름* 위치**: `struct Counter`의 range는 `3:8`(C 위치)이지 `3:1`(`public` 위치)이 아님. 슬라이스에 attribute 보존하려면 column 무시하고 *startLine 시작 ~ endLine 끝* 까지 라인 단위로 잘라야 함. SourceRangeMapper에 `substringForLines` 헬퍼로 캡슐화.
- **AST의 paren-aware 정규식 함정**: `(declref_expr [^)]*?decl="…"`는 `decl="…(file)…"` 안의 paren 때문에 매치 실패. `[^)]*?` 대신 `\b.*?` lazy match로 해결. AST 정규식은 항상 paren-aware sample로 단위 테스트해야.
- **range= 없는 AST 노드 attribution**: `(type_unqualified_ident id="X")`처럼 자체 range= 없는 노드는 직전 부모 range를 상속해야 enclosing 필터가 정확. ReferenceCollector는 last-seen anchor를 추적.
- **swiftc decl chain의 base name 추출**: `sample.(file).Counter.value` → `Counter` (멤버 접근의 owner type), `sample.(file).Counter.init(value:)` → `Counter`. 끝의 `(...)` argument labels suffix 제거 + `(file)` 합성 segment 제거 + segments[1] (module 다음 user-defined) 사용.
- **들여쓰기로 top-level 판별의 안정성**: swiftc의 AST 텍스트는 일관된 2-space 들여쓰기를 사용. Swift 6.x 내내 안정. 단위 테스트의 sample AST가 회귀 신호.
- **`signatureKey` 충돌: type body vs extension** (Codex stop-time review 지적): `struct Counter`와 `extension Counter`는 둘 다 `name="Counter"` + `signatureKey="Counter"`로 색인됨. BFS의 visited set이 signatureKey 기반이면 둘 중 하나만 들어가고 나머지가 누락 → extension 메서드를 호출하는 슬라이스가 self-typecheck 실패.
- **`startLine` 충돌: 같은 라인 multi-decl** (Codex stop-time review 두 번째 지적): `typealias Foo = Int; typealias Bar = String` 같은 single-line multi-decl은 두 entry 모두 `startLine == 1`. visited 키가 startLine만이면 또 silent drop. 수정: visited 키를 *Entry 자체*(name + signatureKey + kind + 전체 source range를 모두 포함하는 Hashable)로 변경. 세 가지 충돌(struct+extension, single-line multi-decl, ordinary overload)을 모두 한 번에 해소.
- **`typealias` 노드는 `_decl` 서픽스 없음**: 다른 top-level decl은 `(struct_decl …)`/`(func_decl …)`처럼 `_decl` 서픽스를 가지지만 typealias만 `(typealias …)`로 emit됨. DeclIndex 정규식이 `typealias_decl`만 매치하면 typealias가 색인 안 되어 의존 추적이 실패. `(?:_decl)?` 옵셔널로 양 형식 모두 매치.
- **closure → 텍스트 렌더링 시 라인 중복** (Codex stop-time review 세 번째 지적): closure에 같은 라인 두 decl이 있거나 line range가 겹치면 `mapper.substringForLines`를 각각 호출해 동일 텍스트가 두 번 emit됨 → swiftc가 "duplicate definition" 에러. 수정: 렌더링 전에 closure decl들의 `[startLine, endLine]` interval을 union-merge해 disjoint 범위로 축약. 인접하지만 겹치지 않는 범위(`a`가 line 3 끝, `b`가 line 5 시작)는 분리 유지해 `\n\n` join이 원본 빈 줄 모양을 보존.

### Stage 4-3 (완료) — BuildArgsResolver 점진 캐싱

233 tests / 45 suites 통과. PLAN §10 미해결 항목 중 "BuildArgsResolver 결과 캐싱"을 1차 마일스톤으로 도입. SwiftPM/xcodebuild 호출이 같은 입력에 대해 반복 spawn되는 비용을 in-memory cache로 제거.

수행 작업 (3-agent team `stage4-3-cache`로 병렬):
1. ✓ (architect) `BuildInput`에 `Hashable` conform 추가. 모든 associated values(String/[String])가 Hashable이라 자동 합성. `Tests/SwiftcMCPCoreTests/BuildInputTests.swift`에 `BuildInput Hashable` suite (sameValueProducesSameHash, distinctValuesAreDistinctSetMembers).
2. ✓ (architect) `Sources/SwiftcMCPCore/BuildInput/CachedBuildArgsResolver.swift` actor passthrough skeleton — 공개 surface 정의 (init/resolveArgs/clearCache/cachedEntryCount).
3. ✓ (develop) actor 본체 구현. `cache: [BuildInput: ResolvedBuildArgs]` + hit 시 `isStillValid` (inputFiles + searchPaths + frameworkSearchPaths 모두 `FileManager.fileExists` 통과 필요). 실패 시 entry 제거 후 wrapped 재호출.
4. ✓ (develop) `Sources/mcpswx/Mcpswx.swift`에 `let cachedResolver = CachedBuildArgsResolver(wrapping: DefaultBuildArgsResolver())` 1개 인스턴스 → 9개 file/directory-accepting 도구(FindSlowTypecheck/EmitAST/EmitSIL/EmitIR/CompileStats/CallGraph/ConcurrencyAudit/ApiSurface/SliceFunction)에 명시 주입. 코드 문자열 입력 4개 도구는 변경 없음.
5. ✓ (develop) `Tests/SwiftcMCPCoreTests/TestSupport.swift`에 `CountingResolver` 헬퍼 (NSLock + `lock.withLock {}` 사용으로 actor isolation 외부에서도 thread-safe).
6. ✓ (test) `CachedBuildArgsResolverTests.swift` 단위 7건 + 통합 1건. invalidation 테스트는 "1차 resolve 후 입력 파일/searchPath 디렉토리 강제 삭제 → 2차 resolve가 wrapped를 재호출(callCount==2)"로 검증. 통합 timing 테스트(`swiftPMPackageHitsCacheSecondTime`)는 SamplePackage 두 번 resolve 측정 — 두 번째가 첫 번째의 5배+ 빠름이 실측 확인됨.

학습 사항:
- **NSLock + async**: `lock.lock(); defer { lock.unlock() }` 패턴이 `async` 함수의 await 사이에서 lock을 잡고 있으면 actor reentrance 우회 가능성 + Swift 6 strict concurrency가 경고. `lock.withLock {}` 클로저 형태가 안전 — await 없는 동기 영역에서만 lock을 잡고 release.
- **path 존재 검증을 모든 hit에서 수행**: PersistentScratch는 OS 임시 디렉토리 정리에 위임되므로 *수일 후* 사라질 수 있음. cache hit가 stale path를 반환하면 downstream swiftc 호출이 silent 실패. `inputFiles + searchPaths + frameworkSearchPaths` 합쳐서 `allSatisfy { fileExists }`로 검증하고 1개라도 누락이면 무효화.
- **테스트 결정성과 운영 캐시 분리**: 도구 init의 `resolver:` 파라미터는 디폴트 `DefaultBuildArgsResolver()` 유지. Mcpswx만 명시적으로 cached 인스턴스 주입. 기존 233개 테스트는 cache 없는 상태에서 동작해 결정성 보존, 운영 바이너리에만 캐시 적용.
- **3-agent 분업의 unblock 순서**: architect(skeleton + Hashable) → develop(actor 본체 + wiring + 헬퍼) → test(단위 + 통합 + 회귀). architect의 skeleton이 *passthrough*라서 develop이 본체를 채울 때 build를 깨지 않음. test가 실패 발견 시 develop에게 SendMessage로 reassign.

### Stage 4-3 후속 fix — fingerprint invalidation + lock 제거 (Codex review + 사용자 지시)

후속 4-3a 단계로 두 가지 보강:

1. **Codex stop-time review 지적 — fingerprint invalidation**: 1차 4-3은 *path 존재* 검증만 했다. 사용자가 Package.swift를 수정하거나 Sources/에 새 파일을 추가하면 cache hit이 발생해 stale `ResolvedBuildArgs`(예: 새 파일이 빠진 inputFiles)를 반환. 수정: cache entry에 *fingerprint*(`[String: TimeInterval]`, path → mtime epoch sec)를 함께 저장. hit 시 fingerprint 재계산 + 비교, 일치하지 않으면 invalidate. 추적 path 집합:
   - `inputFiles + searchPaths + frameworkSearchPaths` (resolved 결과의 전체 path) — 항상.
   - `manifestPaths(for: input)` (case별):
     - `.file(path)` → `[path]`.
     - `.directory(path, ..., searchPaths)` → `[path] + searchPaths`. *디렉토리 mtime은 listing 변경(파일 추가/삭제) 시 OS가 자동 bump*.
     - `.swiftPMPackage(path)` → `[path, path/Package.swift, path/Package.resolved, path/Sources]`.
     - `.xcodeProject(path)` → `[path, path/project.pbxproj]`.
     - `.xcodeWorkspace(path)` → `[path, path/contents.xcworkspacedata]`.
   - missing path는 mtime sentinel `-1`로 저장 → 일치/불일치 모두 추적 가능.
   - 단위 테스트 3건 추가: `invalidatesWhenInputFileMtimeChanges`, `invalidatesWhenDirectoryListingChanges`, `invalidatesWhenSwiftPMManifestChanges`(fingerprint만 검증하기 위한 `StaticPackageResolver` test stub 도입).

2. **사용자 지시 — 모든 lock 제거**: 프로젝트 정책으로 NSLock/os_unfair_lock/atomics 사용 금지. 두 군데 변경:
   - `ProcessRunner.PIDHolder`: `final class @unchecked Sendable` + `NSLock` → `actor`. `set/clear/markCancelled`이 모두 async. `withTaskCancellationHandler.onCancel`은 동기적이라 actor에 직접 접근 불가 → `Task { await holder.markCancelled() }`로 unstructured Task 발사. 약간의 scheduling 지연 추가되나 60s wall-clock fallback 대비 마진 충분.
   - `Tests/SwiftcMCPCoreTests/TestSupport.swift::CountingResolver`: `final class @unchecked Sendable + NSLock` → `actor`. `callCount` 접근부에 `await` 추가.
   - `taskCancellationTerminatesChildProcess` 테스트의 elapsed 임계값 `5.0s` → `7.0s` (actor + Task hop의 추가 ms를 부하 시에도 안전하게 흡수). 60s timeout fallback 대비 8x 마진 유지.

236 tests / 45 suites (이전 233 → +3).

학습 사항 추가:
- **lock 정책**: 본 프로젝트는 lock primitives 미사용. 동시성 안전은 actor 격리만으로 보장. `withTaskCancellationHandler.onCancel`처럼 동기적 콜백에서 actor에 접근해야 하는 경우 *unstructured `Task { await … }`*로 hop, scheduling 지연을 받아들이고 lock-free 유지.
- **fingerprint invalidation의 directory mtime**: 디렉토리 안 파일 추가/삭제 시 OS가 디렉토리 자체의 mtime을 bump. 이 한 가지 신호로 *새 파일 추가* 시나리오를 별도 listing 비교 없이 잡을 수 있다.
- **SwiftPM 레이아웃 — `Sources/<TargetName>` 단위 추적 필요** (Codex review 두 번째 지적): SwiftPM은 `Sources/<TargetName>/*.swift` 구조. 새 파일을 `Sources/Lib/NewFile.swift`로 추가하면 *target 디렉토리 (`Sources/Lib`)*의 mtime은 bump되지만 *상위 `Sources/`*는 변경 안 됨. manifestPaths에 `<pkg>/Sources`만 넣으면 새 파일을 silent miss. 수정: fingerprint에 *모든 inputFiles의 부모 디렉토리*를 자동 포함. 예) inputFile=`/pkg/Sources/Lib/Lib.swift` → 부모 `/pkg/Sources/Lib`도 추적 → 그 디렉토리에 sibling 추가 시 invalidation 발동.
- **부모 한 단계로는 부족 — input root까지 ancestor walk 필요** (Codex review 세 번째 지적): inputFiles이 모두 nested 디렉토리에 있을 때(`Sources/Lib/Sub/*.swift`) 새 파일을 *상위 target dir에 직접* 추가(`Sources/Lib/RootLevel.swift`)하면 `Sources/Lib`의 mtime은 bump되지만 immediate-parent 집합엔 `Sources/Lib/Sub`만. 결국 silent miss. 수정: 부모 한 단계만이 아니라 *input root까지 모든 ancestor*를 fingerprint에 포함.
- **ancestor walk만으로는 *기존 nested dir에 새 파일 추가*가 silent miss** (Codex review 네 번째 지적): SwiftPM은 `Sources/<TargetName>/` 아래를 *recursive*로 탐색. inputFiles=`Sources/App/Y/Existing.swift`만 있을 때 새 파일을 `Sources/App/Y/Later.swift`로 추가하면 *Y의 mtime만* bump되고 `Sources/App`은 변경 없음 (자식 디렉토리 set이 그대로). ancestor walk가 `Sources/App/Y`까지만 추적해도 *그 mtime 변화*는 잡지만, ancestor walk는 *기존 inputFile의 부모 chain*만 본다 — `Y`가 inputFile의 immediate parent라 운 좋게 잡히는 케이스. inputFiles이 다른 nested dir들에만 있고 `Y`는 inputFile 없는 별도 dir이라면 fingerprint 밖. 수정: swiftPMPackage 케이스에서 `Sources/` 아래 *모든 sub-directory를 enumerate*해서 manifestPaths에 추가. SwiftPM의 recursive 동작에 맞춰 모든 디렉토리의 mtime을 추적.
- **xcodeProject/xcodeWorkspace는 pbxproj/xcworkspacedata가 sole authority** — Xcode 빌드 시스템은 *pbxproj 안의 build phases*만 컴파일. 새 `.swift` 파일이 분석에 포함되려면 반드시 pbxproj가 업데이트됨. 따라서 fingerprint는 pbxproj/xcworkspacedata mtime + inputFiles 자체로 충분. `rootPath(for:)`이 xcode 케이스에서 `nil`을 반환해 ancestor walk skip — `.xcodeproj`/`.xcworkspace`의 input source는 *형제 디렉토리*에 있어 ancestor walk가 root match 실패하고 시스템 root까지 false invalidation 일으키는 위험을 회피.
- **workspace는 *referenced pbxproj* 모두 추적해야** (Codex review 다섯 번째 지적): xcodeWorkspace의 fingerprint가 `contents.xcworkspacedata`만 추적하면, 사용자가 Xcode UI에서 *referenced project*의 source를 추가/제거할 때 pbxproj는 변경되지만 contents.xcworkspacedata는 변경 없음 → silent miss. 수정: contents.xcworkspacedata XML을 정규식 파싱(`<FileRef location="…"/>`)해서 referenced `.xcodeproj` 경로 추출 + 각 `project.pbxproj`를 fingerprint에 추가. location prefix 처리: `group:`(workspace 부모 dir 기준), `container:`(workspace 자체 기준), `absolute:`(절대 경로), `self:`(workspace 자체).
- **`StaticPackageResolver` test stub 패턴**: 외부 CLI(`swift package describe`)를 실제 호출하지 않고 fingerprint만 검증하고 싶을 때, BuildArgsResolver 인터페이스를 conform하는 test-only stub을 두면 단위 테스트가 millisecond 단위로 빠르고 결정성도 확보. plan §10의 캐싱 정책 결정 후속 작업에 재사용 가능 패턴.

### Stage 4-3b (완료) — fingerprint에 content hash 추가

254 tests / 47 suites 통과. Stage 4-3 후속 후보 중 *file content hash*. mtime+size 만으로는 mtime-preserving 컨텐츠 변경(`git checkout`, `cp -p`, `touch -r` 후 편집)을 silent miss → cache가 stale 분석을 반환하던 케이스를 닫음.

수행 작업:
1. ✓ `Fingerprint` 타입을 `[String: TimeInterval]` → `[String: Stamp]`로 변경. `Stamp = (mtime: TimeInterval, size: Int64?, contentHash: Data?)`.
2. ✓ `stamp(at:)` 헬퍼: 정규 파일이면 항상 `SHA256.hash(data:)` (CryptoKit) 추가. 디렉토리·없는 path는 contentHash=nil.
3. ✓ `makeFingerprint`은 `paths` 전체를 `stamp(at:)`에 그대로 흘려보냄 — regular-file gate가 stamp 안에 있어 inputFiles와 매니페스트(Package.swift, Package.resolved, project.pbxproj, contents.xcworkspacedata, referenced pbxproj)를 동일하게 hash한다.
4. ✓ 단위 테스트 추가 (2건): `invalidatesWhenContentChangesButMtimeAndSizePreserved`(inputFile), `invalidatesWhenManifestContentChangesButMtimeAndSizePreserved`(Package.swift). 둘 다 정수 epoch로 mtime 핀 + 같은 길이 두 본문 + APFS round-trip 확인. 기존 14 단위 테스트 회귀 0.
5. ✓ 통합 테스트 `swiftPMPackageHitsCacheSecondTime`: 2번째 호출이 여전히 첫 호출 대비 5x+ 빠름 — hash I/O가 캐시 ROI를 의미 있게 깎지 않음을 입증.

학습 사항:
- **CryptoKit는 외부 의존이 아님**: 프로젝트의 "Foundation only" 정책은 MCP 와이어 레이어(외부 라이브러리 금지)에 적용. CryptoKit은 macOS 13+ / Swift 6.0+에 항상 동봉되는 시스템 프레임워크라 third-party 의존성이 아님. SHA-256 한 곳 호출이라 직접 구현보다 표준 호출이 안전.
- **APFS sub-second mtime의 round-trip 함정**: `setAttributes(.modificationDate: someDate)`가 fractional second를 보존하더라도, Date↔ TimeInterval ↔ FS 저장 ↔ 다시 Date 복원 경로에서 마지막 비트가 어긋나는 경우가 있어 두 Date의 `==`가 실패할 수 있다. 테스트에서 mtime 핀이 필요하면 정수 epoch(`Date(timeIntervalSince1970: 1_700_000_000)`)를 사용해 round-trip을 깨끗이 만든다.
- **hash 정책: 모든 추적 정규 파일** (Codex review 추가 지적): inputFiles만 hash하면 매니페스트(Package.swift, project.pbxproj, contents.xcworkspacedata, referenced pbxproj)가 mtime+size 보존 편집에서 silent stale로 남는다 — 정확히 git checkout / Xcode in-place rewrite의 시나리오. regular-file 판정을 `stamp(at:)` 내부로 옮기면 디렉토리는 자동으로 hash 제외, 호출부는 path 종류를 신경 쓸 필요 없이 동일하게 다룬다.
- **cache hit-validate 비용 vs ROI**: 단순 `swiftc -typecheck` 입력 1~2 파일(~수 KB)은 hash 비용 ~0.1ms 미만. 100파일 SwiftPM target + 매니페스트도 ~1MB 분량 ≪ 1ms. xcodeWorkspace의 referenced pbxproj가 1MB여도 ~1ms. 우회되는 resolver 호출(`swift package describe`, `xcodebuild -showBuildSettings`)은 수백 ms 이상이라 ROI 유지.

### Stage 4-4 (완료) — `api_diff`: Swift API breakage 검출

252 tests / 47 suites 통과. PLAN §8 후속 후보 중 *API diff*. `swift-api-digester` CLI를 wrapping해 두 시점의 모듈 API surface를 비교하고 카테고리별 변화를 구조화 결과로 반환.

수행 작업:
1. ✓ `Toolchain/ApiDigesterParser.swift` — `-diagnose-sdk` 텍스트 출력을 12개 카테고리(removed/moved/renamed/type/declAttribute/fixedLayout/protocolConformance/protocolRequirement/classInheritance/genericSignature/rawRepresentable/others)로 파싱. 모르는 헤더는 `others` 버킷에 떨어뜨려 toolchain 업그레이드 시 silent drop 회피.
2. ✓ `Tools/ApiDiff.swift` — 두 BuildInput(baseline+current) → 각 입력에 대해 `.swiftmodule` materialize → swift-api-digester `-dump-sdk` 두 번 → `-diagnose-sdk` 한 번 → parser → 응답.
3. ✓ `.swiftmodule` 산출 전략: file/directory는 `swiftc -emit-module` 직접 호출 후 PersistentScratch에 둠, swiftPMPackage는 SwiftPMPackageResolver의 searchPaths 첫 항목 재사용. xcodeProject/xcodeWorkspace는 `MCPError.invalidParams`로 1차 거절.
4. ✓ Mcpswx 등록 (cachedResolver 주입, 총 14 도구).
5. ✓ Fixture: `Tests/Fixtures/ApiDiff/V{1,2}/Lib.swift` — V1=Counter+helloAdd, V2=Counter+doubled+newApi (helloAdd removed).
6. ✓ 단위 6 (parser 12 섹션, 빈 입력, 헤더 only, 다중 finding, "API breakage:" prefix 보존, unknown section→others) + 통합 7 (V1↔V2 removed, ABI 모드 added, 동일 버전 empty, module_name 누락 reject, xcode 케이스 reject, dep-less swiftPMPackage self-diff, dep-having App→Core swiftPMPackage self-diff).

학습 사항:
- **swift-api-digester는 진단을 *stderr*로 출력**: 첫 probe에서 `2>&1`로 합쳐 보다가 도구는 stdout만 파싱했더니 모든 finding이 빈 배열로 떨어졌다. `-compiler-style-diags` 유무 무관하게 `/* Section */` 텍스트는 stderr로 emit. 도구의 `rawDiagnoseOutput`/parser 입력 모두 `process.standardError`. (Stage 4-1의 swiftc dump-ast가 stdout이었던 것과 정반대 — 둘 다 같은 toolchain이지만 sub-tool마다 다르므로 항상 probe로 확정해야 함.)
- **`-json` flag 미작용**: swift-api-digester가 `-json -o file.json`을 받아도 같은 텍스트가 파일에 저장됨. JSON 출력 모드는 deserialize-diff 같은 다른 모드에만 의미 있고, diagnose-sdk는 텍스트 채널만. 텍스트 파서가 사실상 1차 채널.
- **`WritableKeyPath`는 `Sendable` 아님**: section title → keypath dictionary로 파서 분기를 표현하려 했으나 Swift 6 strict concurrency가 static let에 거절. 내부 enum + switch로 해결 (12-way switch가 keypath dictionary보다 가독성도 더 나음).
- **swiftPMPackage 분석 대상 모듈은 resolver의 부산물이 아님** (Codex review 지적): SwiftPMPackageResolver는 *target_dependencies가 비어 있으면* `swift build`를 건너뜀 → searchPaths empty. api_diff가 `searchPaths.first`로 분석 대상 .swiftmodule을 찾으려 하면 dep-less 패키지(가장 흔한 케이스 SamplePackage)에서 즉시 실패. 수정: swiftPMPackage 케이스를 file/directory와 같은 코드 path로 통합 — `resolved.inputFiles`를 받아 `swiftc -emit-module` 직접 호출, `resolved.searchPaths`(있을 시)는 의존 모듈 import용 -I로 전달. resolver 부산물에 의존하지 않으므로 dep 유무 모두 동작.
- **`-dump-sdk`도 의존 모듈 -I가 필요** (Codex 후속 지적): emit-module 단계만 의존 search path를 받고 dump-sdk는 우리가 새로 emit한 디렉토리만 받게 했더니, App→Core 같은 의존 패키지에서 dump-sdk가 `import Core`를 해석하지 못해 실패. swift-api-digester가 모듈 인터페이스를 로드할 때도 swiftc와 동일한 모듈 검색 환경이 필요한 것이 원인. 수정: `materializeModule`이 `MaterializedModule { moduleDir, dependencySearchPaths }`를 반환하고, `runDump`가 `includePaths: [String]`을 받아 모든 경로를 `-I`로 풀어 넘김. 회귀 테스트는 MultiTargetPackage `App` 타깃 self-diff로 의존 import가 dump 단계까지 살아남는지 검증.

### Stage 4-4b (완료) — `api_diff` xcodeProject/xcodeWorkspace 입력 지원

255 tests / 47 suites 통과. Stage 4-4의 1차 마일스톤에서 거절했던 두 case를 열었다. 별도 추출 로직은 필요 없었다 — `XcodebuildResolver`가 이미 `inputFiles + extraSwiftcArgs(-sdk + -swift-version)` 형태로 swiftc-ready output을 돌려주므로, file/directory/swiftPMPackage와 정확히 같은 `swiftc -emit-module` path를 재사용한다.

수행 작업:
1. ✓ `Tools/ApiDiff.swift::materializeModule`의 `switch input { case .file, .directory, .swiftPMPackage … case .xcodeProject, .xcodeWorkspace: throw … }` 분기 제거. 모든 case가 동일 코드 path 통과.
2. ✓ 헤더 doc 갱신 — pipeline §1을 모든 BuildInput 지원으로 다시 씀.
3. ✓ `MaterializedModule`을 `{ moduleDir, dependencySearchPaths, frameworkSearchPaths, sdkPath }`로 확장. `runDump`가 `-F <framework path>`와 `-sdk <SDKROOT>`를 함께 emit. SDK 경로는 `extraSwiftcArgs`에서 `-sdk` 토큰 다음 값을 직접 추출.
4. ✓ `xcodeInputCurrentlyRejected` 단위 테스트를 `xcodeProjectSelfDiffsCleanly` 통합 테스트로 재작성. SampleProject(static lib, 단일 .swift, framework dep 없음) self-diff → 0 findings 검증. CachedBuildArgsResolver를 baseline/current 사이에 공유해 xcodebuild 호출 1회로 절감.

학습 사항:
- **XcodebuildResolver 출력은 swiftc-ready**: 1차 Stage 4-4에서 xcode 케이스를 deferred로 표시한 이유는 ".swiftmodule 위치 추출 probe 필요"였으나, 실제로 `.swiftmodule` 위치 자체는 *우리가 직접 emit*하므로 추출이 불필요했다. resolver는 Xcode가 결정한 inputFiles + SDK/Swift 버전만 알려주면 충분 — 나머지는 swiftPMPackage/file/directory와 동일하게 흘러간다. 1차 결정은 over-conservative.
- **dump-sdk도 SDK/-F가 필요** (Codex 후속 지적): emit-module은 swiftc가 받는 모든 인자(-sdk, -F)를 그대로 받지만, swift-api-digester `-dump-sdk` 호출에 같은 인자를 안 넘기면 디지스터가 *기본 SDK*로 모듈 인터페이스를 로드 → Apple 프레임워크 import (UIKit/Foundation) 해석 실패하거나 SDK 버전 mismatch로 type lookup 실패. swift-api-digester는 `-sdk`, `-F`, `-Fsystem`, `-I`를 모두 받으므로 emit-module과 동일하게 그대로 전달. 같은 종류의 silent-miss 패턴이 dependencySearchPaths에서도 있었음 (Stage 4-4 첫 후속 fix와 동형).
- **xcodebuild stdio nullDevice 우회** (macOS 26.2+ / Xcode 26.2+): SWBBuildService 자식이 부모의 stdout/stderr FD를 상속받고 BUILD SUCCEEDED 후에도 닫지 않아 `readDataToEndOfFile()`이 영원히 블록. `runProcessWithTimeoutDiscardingOutput` (FileHandle.nullDevice + 5분 wall-clock + SIGTERM/SIGKILL 에스컬레이션)으로 우회. SwiftFileList 존재로 빌드 성공 판정. Process 자체에는 `runProcess`/`runProcessWithTimeout`과 동일한 `withTaskCancellationHandler` + `PIDHolder` 패턴을 사용해 부모 task cancel → 자식 SIGTERM 계약을 보존 (Codex 후속 지적 — 우회 헬퍼가 cancel 전파를 깨뜨릴 위험). 단위 테스트 `parentTaskCancelTerminatesChild`이 60초 sleep을 띄우고 200ms 후 cancel → 7초 내 종료를 검증.
- **테스트에서 cachedResolver 공유**: `ApiDiffTool(toolchain:resolver:)`에 명시적으로 `CachedBuildArgsResolver`를 주입하면 baseline=current self-diff 테스트가 xcodebuild를 한 번만 실행 → CI 시간 절반. 프로덕션(Mcpswx)에서는 이미 cachedResolver가 주입돼 있으니 동일 입력 두 번에서도 자연스럽게 캐시 hit.

### Stage 4 후속 후보 (윤곽만)

- Workspace build perf (`xcbuild_perf`) — xcactivitylog 자체 파서.
- Stage 4-2 후속: 디렉토리/모듈 입력 슬라이싱 (slice_function 현재는 file 단일).
- Stage 4-4b 후속 (관찰): xcode 입력에서 *user framework dependency*가 있을 때(예: App→Framework). 현재 `XcodebuildResolver`가 frameworkSearchPaths를 빈 배열로 반환 → import 해석 실패 가능. SampleProject는 dep 없는 static lib라 통과. 후속에서 xcodebuild build 결과의 `<SYMROOT>/<config>/` 또는 OBJROOT의 모듈 경로를 frameworkSearchPaths로 채워야 함.

각 Stage 진입 시 분기점 절차로 PLAN을 갱신한다.

## 9. 비-Stage 정책

다음은 모든 Stage에 적용되는 정책이다.

- **Toolchain 해석 우선순위**: `TOOLCHAINS` env → `xcrun -f swiftc` → `PATH`. 결과 toolchain 경로와 버전을 모든 도구 응답의 메타에 포함.
- **AST/SIL 포맷 비안정성**: 외부에 산출물을 노출할 때 toolchain 버전을 함께 반환. 컴파일러 버전 간 포맷 호환을 약속하지 않는다.
- **호출별 임시 디렉토리**: 두 종류로 분리.
  - `CallScratch` (`$TMPDIR/swiftmcp-<uuid>/`): 호출 처리 동안에만 사용되는 작업 디렉토리. 호출 종료 시 정리(`dispose()` 또는 deinit).
  - `PersistentScratch` (`$TMPDIR/swiftmcp-out-<uuid>/`): 도구 응답으로 *경로*를 노출하는 산출물용. 호출 종료 후에도 보존되어 클라이언트가 파일을 열 수 있음. OS의 임시 디렉토리 정리 정책에 위임.
- **컴파일러 호출 vs 빌드**: 분석 호출(`-typecheck` 등)은 오브젝트 산출 없이 끝나도록 한다. 빌드 캐시 오염 방지.
- **swiftc cwd-neutral 호출**: emit-module 류 옵션은 명시적 출력 경로 필요. 산출물은 항상 PersistentScratch 또는 CallScratch에 격리. 본 MCP가 사용자 프로젝트 디렉토리에서 호출돼도 cwd 오염 없음.
- **stdio 분리**: 자식 프로세스 stdout/stderr는 부모 stdio와 절대 섞이지 않는다 (Pipe 사용).
- **응답 직렬화**: stdout 쓰기는 actor로 직렬화 — 한 번에 한 줄(JSON + `\n`) 단위로만 atomic.
- **인자 검증**: `swiftc -frontend -emit-supported-arguments`로 받은 토큰 화이트리스트로 동적 검증. 사용자 입력 옵션은 화이트리스트 통과 후 호출.
- **Hidden 옵션 노출 정책**: 본 MCP가 외부에 인자로 노출하는 화이트리스트는 `swiftc --help` 기준. `-help-hidden`/`-frontend -help-hidden`의 옵션은 도구 내부에서만 사용. 사용자가 임의 옵션을 패스하는 채널은 두지 않는다.
- **JSON 키 명명**: 도구 결과의 JSON 키는 Swift property 이름을 그대로 사용한다(camelCase). MCP envelope(`protocolVersion` 등)과 같은 컨벤션을 도구 결과에도 유지하여 한 응답에 두 컨벤션이 섞이지 않게 한다.
- **테스트 실행**: `swift test`만 사용. `--parallel`은 macOS 26 환경에서 deadlock하므로 사용 금지.

## 10. Open Questions

- `build_isolated_snippet`의 sandbox 정책 (Stage 4 격리 실행 고도화 시 결정).
- progress 노티피케이션 도입 시점 (Stage 3.C/3.D의 SwiftPM/xcodebuild 호출이 길어지면 검토).
- CLI 진입점(`mcpswx-cli`)의 도입 시점 (Stage 3 종료 후 재검토).
- ~~BuildArgsResolver 결과 캐싱 정책 (Stage 3 종료 후).~~ → Stage 4-3에서 결정·도입. in-memory + path 존재 검증. mtime/disk 영속화는 후속.
- "playground/실행 모델 추가"가 본 MCP에 흡수될지, 별도 서버로 분리될지 (Stage 4+ 결정).

## 11. 진행 규칙

- Stage 종료 조건은 검증 명령(빌드·테스트·실행)으로 표현되어야 한다. "거의 다 됐다"는 종료가 아니다.
- Stage 진입 전 PLAN을 읽고, 종료 후 PLAN을 갱신한다.
- 결정 항목을 변경할 때는 본 문서의 해당 절을 새로 쓴 형태로 교체한다 (이력은 git에 둔다).
