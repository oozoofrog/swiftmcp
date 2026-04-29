---
library: swift-static-analysis
version: "Apple Swift 6.3.1 / Xcode 26 toolchain 기준"
collected: "2026-04-30"
sources:
  - local-binary: "swiftc -help-hidden / -frontend -help-hidden"
  - local-binary: "swift-driver, xcodebuild, swift package"
  - cross-ref: ".claude/references/swiftc.md"
---

# Swift Static Analysis — 본 MCP가 제공할 수 있는 분석 기능 카탈로그

## 0. 범위

본 문서는 본 MCP(`mcpswx`)가 Swift 코드에 대해 제공할 수 있는 정적 분석 기능을 카테고리화한 조사 결과입니다.

- 모든 분석은 (a) toolchain 자체 기능, (b) toolchain 산출물의 후처리, (c) 표준 Apple CLI(`xcodebuild`, `swift package`)를 호출한 산출물의 후처리, 셋 중 하나입니다.
- 입력 도메인: 단일 `.swift` 파일, 소스 디렉토리, Swift 모듈, SwiftPM 패키지, Xcode 프로젝트/워크스페이스.
- 타깃 플랫폼: macOS, iOS, iPadOS, watchOS, tvOS, visionOS, simulator 변형, macCatalyst.

## 1. 분석 카테고리 한눈에

| # | 카테고리 | 1차 출처 | MCP 도구 후보 |
|---|---|---|---|
| A | 빌드 퍼포먼스 (type-check / 함수 본문 시간) | `swiftc -Xfrontend -warn-long-*` / `-stats-output-dir` / xcactivitylog | `analyze_build_perf`, `find_slow_typecheck` |
| B | 모듈 의존 관계 (선언 vs 실제 import) | `-emit-loaded-module-trace` / `-scan-dependencies` / SwiftPM·xcodebuild 출력 | `module_graph`, `import_diff` |
| C | 복잡도 / 호출 정보 | SIL (`-emit-sil`) / AST (`-dump-ast`) | `function_complexity`, `call_graph` |
| D | API 표면 / breaking change | `-emit-symbol-graph` / `-emit-api-descriptor` / API digester | `api_surface`, `api_diff` |
| E | 데드 코드 / 미사용 | index store + symbol graph | `find_dead_code` |
| F | 언어 모델 위반 (concurrency·memory·availability) | `-strict-concurrency` / `-strict-memory-safety` / `-warn-*` | `concurrency_audit`, `availability_audit` |
| G | 매크로 / 플러그인 | `-Rmacro-loading` / `-load-plugin-*` | `macro_trace` |
| H | 빌드 그래프 / 잡 라이프사이클 | `-driver-print-jobs` / `-driver-print-graphviz` | `driver_jobs` |
| I | 워크스페이스 빌드 로그 (xcactivitylog) | `xcodebuild` 산출 + 자체 SLF 파서 | `xcbuild_perf` |

## 2. 카테고리 A — 빌드 퍼포먼스

컴파일러 frontend가 이미 진단·통계 수단을 제공합니다.

### 2.1 Type-checker 폭주 탐지

```sh
swiftc -typecheck \
  -Xfrontend -warn-long-expression-type-checking=200 \
  -Xfrontend -warn-long-function-bodies=200 \
  <files...>
```

- `-warn-long-expression-type-checking=<ms>` — 임계값 초과 표현식 워닝
- `-warn-long-function-bodies=<ms>` — 임계값 초과 함수 본문 워닝
- 두 옵션은 frontend-only — driver 호출 시 `-Xfrontend`로 패스스루
- 임계값은 정수(밀리초); 0 = 비활성

> **MCP 도구 매핑**: `find_slow_typecheck(target, ms_threshold)` — 워닝 라인을 파싱해 `[{file,line,col,ms,kind}]` 반환.

### 2.2 컴파일 통계 디렉토리

```sh
swiftc -typecheck -stats-output-dir build/stats <files...>
swiftc -typecheck -stats-output-dir build/stats -trace-stats-events <files...>
```

- frontend가 `stats-<job-id>-*.json`을 디렉토리에 떨굼
- 카운터: AST 노드 수, 타입체크 호출 수, solver 시도 수, request 수
- `-trace-stats-events` — 변화량 시간축 트레이싱
- `-profile-stats-entities` — 소스 엔티티(선언)별 집계
- `-profile-stats-events` — 이벤트별 집계
- `-print-zero-stats` — 0 값 포함

> **MCP 도구 매핑**: `compile_stats(target, mode={summary|trace|by_entity})` — JSON 집계 후 상위 N개 hot spot.

### 2.3 함수 본문 / 표현식 시간 자세히

```sh
swiftc -typecheck \
  -Xfrontend -debug-time-function-bodies \
  -Xfrontend -debug-time-expression-type-checking \
  -Xfrontend -debug-time-compilation \
  <files...>
```

- 모든 함수/표현식 처리 시간을 stderr로 출력 (워닝과 달리 임계 없이 전부)
- 출력량이 매우 큼 — 단일 파일/소형 모듈에 적합

### 2.4 Driver 단계 시간

```sh
swiftc -driver-time-compilation <files...>
swiftc -driver-print-jobs <files...>
swiftc -driver-show-job-lifecycle <files...>
```

### 2.5 Skip non-inlinable (인터페이스 빌드 가속)

```sh
swiftc -experimental-skip-non-inlinable-function-bodies-without-types <files...>
```

- 인라인 불가 함수 본문 type-check + SILGen 건너뛰기
- 본 MCP는 켜기 자체보다 "이 옵션을 켜면 X% 단축됨"을 추정해 주는 추천 도구로 활용.

### 2.6 Xcode 빌드 로그 (xcactivitylog)

- `xcodebuild`가 `~/Library/Developer/Xcode/DerivedData/<project>/Logs/Build/*.xcactivitylog`에 압축 로그 산출
- 형식은 SLF(Self-Contained Log Format) — 본 MCP가 자체 파서로 직접 해석 가능
- 단계별 시간 / 타깃별 시간 / 병렬도 분석

> **MCP 도구 매핑**: `xcbuild_perf(project_or_workspace, scheme, configuration)` — critical path / slowest targets / 병렬도 산출.

## 3. 카테고리 B — 모듈 의존 관계

### 3.1 Loaded Module Trace (실제 import 사실)

```sh
swiftc -typecheck \
  -emit-loaded-module-trace \
  -emit-loaded-module-trace-path build/trace.json \
  <files...>
```

- 컴파일에서 실제 로드된 모든 모듈 JSON
- 직접 import + transitive import 모두 포함
- frontend 잡마다 한 줄(JSON Lines) 누적 — 단일 객체가 아님

### 3.2 Dependency Scanner

```sh
swiftc -scan-dependencies <file.swift>
swiftc -scan-dependencies -explicit-module-build <file.swift>
swiftc -print-explicit-dependency-graph -explicit-dependency-graph-format=json
swiftc -print-preprocessed-explicit-dependency-graph
```

- 컴파일 전 단계에서 의존 모듈 그래프 산출 (Swift + Clang + bridging header)
- `-explicit-dependency-graph-format=<json|dot>`

### 3.3 Module dependency 설명 (왜 이게 import되었는가)

```sh
swiftc -explain-module-dependency Foundation <files...>
swiftc -explain-module-dependency-detailed Foundation <files...>
```

- 특정 모듈이 의존성에 들어온 경로를 remark로 출력

### 3.4 Cross-import 검출

```sh
swiftc -typecheck -Rcross-import <files...>
```

- 자동으로 끌어들이는 cross-import overlay에 대한 remark

### 3.5 빌드 시스템 메타데이터 결합

선언된 의존성은 사용 중인 빌드 시스템에서 추출:
- **SwiftPM**: `swift package describe --type json` / `swift package show-dependencies --format json`
- **xcodebuild**: `xcodebuild -showBuildSettings -project ... -target ...` (`SWIFT_INCLUDE_PATHS`, `FRAMEWORK_SEARCH_PATHS`, link 플래그)

선언된 의존성과 (3.1) 실제 trace를 diff하면:
- 선언만 있고 실제 import 없음 → 잉여 의존성 (빌드 시간 낭비)
- 실제 import는 있는데 선언 누락 → transitive 의존에 의존 (위험)

> **MCP 도구 매핑**: `module_graph(scope)`, `import_diff(declared, observed)`.

### 3.6 Module summary

```sh
swiftc -emit-module -emit-module-summary -emit-module-summary-path M.summary <files>
```

## 4. 카테고리 C — 복잡도 / 호출 정보

### 4.1 SIL 기반 호출 그래프

```sh
swiftc -emit-silgen <file.swift>      # raw SIL
swiftc -emit-sil    <file.swift>      # canonical SIL
swiftc -emit-sil -O <file.swift>      # 최적화된 SIL
```

호출 관련 SIL instructions:
- `apply` / `try_apply` / `begin_apply` — 직접 함수 호출
- `partial_apply` — 클로저 캡처
- `witness_method` — 프로토콜 위트니스 (동적 디스패치)
- `class_method` / `super_method` / `objc_method` — vtable / objc 디스패치
- `function_ref` / `dynamic_function_ref` / `prev_dynamic_function_ref`

추출 가능한 정보:
- caller→callee 그래프
- 재귀(SCC), 도달 불능 함수
- 동적 디스패치 비율 (witness/class_method 카운트)
- 클로저 캡처 빈도 (partial_apply)

> **MCP 도구 매핑**: `call_graph(file_or_module, optimization_level)`.

### 4.2 함수 복잡도

SIL 기반:
- 함수당 SIL 명령 수
- basic block 수
- branch 명령 수 → cyclomatic complexity 근사

AST 기반 (`-dump-ast`/`-dump-ast-format json`):
- 중첩 깊이, 인자 수, 클로저 깊이, 사이클로매틱(if/guard/for/while/switch case)

### 4.3 인라인 트리

```sh
swiftc -frontend -emit-ir -Xllvm -print-llvm-inline-tree <file.swift>
```

### 4.4 최적화 보고

```sh
swiftc -O \
  -save-optimization-record \
  -save-optimization-record-path opt.yaml \
  <files...>
```

- `-Rpass=<regex>` / `-Rpass-missed=<regex>` 로 진단 형태로도 수집 가능

## 5. 카테고리 D — API 표면 / Breaking Change

### 5.1 Symbol Graph

```sh
swiftc -emit-module \
  -emit-symbol-graph \
  -emit-symbol-graph-dir build/symbolgraph \
  -module-name M <files>
```

옵션:
- `-include-spi-symbols`
- `-symbol-graph-minimum-access-level <public|internal|...>`
- `-symbol-graph-pretty-print`
- `-emit-extension-block-symbols` / `-omit-extension-block-symbols`

DocC와 동일 포맷. 모든 심볼·관계·conformance·extension JSON.

### 5.2 API Descriptor

```sh
swiftc -emit-api-descriptor -emit-api-descriptor-path api.json <files>
```

### 5.3 API Digester

```sh
# baseline 생성
swiftc -emit-digester-baseline -emit-digester-baseline-path baseline.json <files>

# 비교
swiftc -compare-to-baseline-path baseline.json -digester-mode api <files>
swiftc -compare-to-baseline-path baseline.json -digester-mode abi <files>
swiftc -digester-breakage-allowlist-path allow.txt ...
swiftc -serialize-breaking-changes-path changes.json ...
```

> **MCP 도구 매핑**: `api_diff(module, baseline_path, mode={api|abi})`.

## 6. 카테고리 E — 데드 코드 / 미사용

### 6.1 Index store

```sh
swiftc -typecheck -index-store-path build/index <files...>
```

- SourceKit이 사용하는 cross-reference 인덱스
- 호출자/참조 관계 추적

### 6.2 Symbol graph + 호출 그래프 결합

- (5.1)의 모든 public symbol 중 (4.1)의 callee로 등장하지 않는 심볼 = 데드 후보
- dynamic dispatch / objc / KVO 때문에 100% 정확하지 않음 — 검증 단계 필수

> **MCP 도구 매핑**: `find_dead_code(scope, accuracy={fast|strict})`.

## 7. 카테고리 F — 언어 모델 위반

### 7.1 Strict Concurrency

```sh
swiftc -typecheck \
  -strict-concurrency=complete \
  -warn-concurrency \
  -enable-actor-data-race-checks \
  -default-isolation MainActor \
  <files...>
```

`<minimal|targeted|complete>` — Sendable·격리 검사 강도.

### 7.2 Strict Memory Safety

```sh
swiftc -typecheck -strict-memory-safety <files...>
swiftc -typecheck -strict-memory-safety:migrate <files...>
```

### 7.3 Heap allocation 검출 (hidden)

```sh
swiftc -typecheck -no-allocations <files...>
```

- 클래스/클로저 등 힙 할당 코드 진단
- 임베디드/실시간 코드 분석에 적합 (일반 앱 코드는 false positive 많음)

### 7.4 Availability 명시 강제

```sh
swiftc -typecheck \
  -require-explicit-availability=warn \
  -require-explicit-availability-target "iOS 16.0" \
  <files...>
```

### 7.5 Sendable 명시 강제

```sh
swiftc -typecheck -require-explicit-sendable <files...>
```

### 7.6 Implicit override 경고

```sh
swiftc -typecheck -warn-implicit-overrides <files...>
```

### 7.7 Soft-deprecated (hidden)

```sh
swiftc -typecheck -warn-soft-deprecated <files...>
```

### 7.8 Werror by group (hidden)

```sh
swiftc -typecheck -Werror StringInterpolation -Wwarning DeprecatedDeclaration <files>
```

- 진단 그룹 단위 warning↔error 변환
- 그룹 목록은 `-print-diagnostic-groups`로 표시

### 7.9 Sanitize (런타임 instrumentation; 빌드 영향)

```sh
swiftc -sanitize=address ...
swiftc -sanitize=thread ...
swiftc -sanitize=undefined ...
```

> **MCP 도구 매핑**:
> - `concurrency_audit(scope)` — `-strict-concurrency=complete` 컴파일 후 진단 카테고리화
> - `availability_audit(scope, target)`
> - `sendable_audit(scope)`
> - `diagnostic_group_summary(scope)` — 진단 그룹별 카운트

## 8. 카테고리 G — 매크로 / 플러그인

### 8.1 매크로 로드 트레이스

```sh
swiftc -typecheck -Rmacro-loading <files...>
```

### 8.2 매크로 확장 인스펙션

```sh
swiftc -dump-ast <files...>          # 확장된 AST
swiftc -emit-silgen <files...>       # 확장 결과의 SIL
```

> **MCP 도구 매핑**: `macro_expansions(file)` — 매크로별 확장 결과 + 컴파일 비용.

## 9. 카테고리 H — Driver 잡 그래프

```sh
swiftc -driver-print-actions <files>      # 액션 트리
swiftc -driver-print-bindings <files>     # 입출력 바인딩
swiftc -driver-print-jobs <files>         # 실행 잡 리스트
swiftc -driver-print-graphviz <files>     # 잡 그래프 graphviz
swiftc -driver-show-incremental <files>   # incremental 빌드 사유
```

- driver의 잡 단위 분석
- incremental 빌드가 깨진 이유 진단에 핵심

## 10. 카테고리 I — 워크스페이스 빌드 로그

본 MCP가 표준으로 호출 가능한 Apple CLI:

| 도구 | 입력 | 출력 |
|---|---|---|
| `xcodebuild` | project/workspace + scheme | `*.xcactivitylog` (DerivedData) |
| `xcodebuild -showBuildSettings` | project/workspace + scheme | 모든 빌드 설정 |
| `swift package describe --type json` | `Package.swift` | 타깃·의존성 메타데이터 |
| `swift package show-dependencies --format json` | `Package.swift` | 의존 그래프 |

xcactivitylog는 SLF 포맷 — 본 MCP가 자체 파서를 두어 외부 의존성 없이 해석.

> **MCP 도구 매핑**: `workspace_build_perf(project_or_workspace, scheme)`, `package_graph(package_path)`.

## 11. 1차 도구 후보 (우선순위)

| 우선순위 | 도구명 | 입력 | 출력 | 1차 출처 |
|---|---|---|---|---|
| 1 | `find_slow_typecheck` | files, ms | `[{file,line,col,ms,kind}]` | `-warn-long-expression-type-checking`, `-warn-long-function-bodies` |
| 2 | `module_import_diff` | scope | declared vs observed import 차이 | 빌드 시스템 메타 + `-emit-loaded-module-trace` |
| 3 | `compile_stats` | files | hot spot top-N (request, type-check, solver) | `-stats-output-dir` |
| 4 | `call_graph` | file or module | caller→callee + dynamic dispatch ratio | `-emit-sil` |
| 5 | `api_surface` | module | public symbol JSON | `-emit-symbol-graph` + `-emit-api-descriptor` |
| 6 | `api_diff` | module + baseline | breaking change 리스트 | `-compare-to-baseline-path` |
| 7 | `concurrency_audit` | scope, level | 진단 카테고리별 카운트 | `-strict-concurrency=complete` |
| 8 | `xcbuild_perf` | project/workspace, scheme | 타깃별 빌드 시간 + critical path | xcactivitylog |

## 12. 통합 시 주의 (Pitfalls)

- **AST JSON 비안정성**: `-dump-ast -dump-ast-format json`은 컴파일러 버전 간 호환 보장 없음. 외부 노출 시 toolchain 버전 동봉.
- **SIL 출력 안정성**: SIL 텍스트 포맷도 안정 보장 없음. 호출 그래프 추출은 *명령 종류*만 의존하고 메타데이터는 보지 말 것.
- **Stats 디렉토리 누적**: `-stats-output-dir`는 호출마다 누적. MCP는 매 호출 임시 디렉토리를 새로 만들고 끝에 정리.
- **Loaded module trace는 frontend 산출**: 멀티 파일 빌드 시 잡마다 한 줄 누적되는 JSONL. 단일 객체 아님.
- **Index store 권한**: SourceKit이 사용 중이면 lock 충돌. 분석 전용 별도 store 디렉토리 권장.
- **`-Xfrontend` 패스스루**: type-check 시간 측정 옵션은 모두 frontend-only. driver 호출 시 반드시 `-Xfrontend`.
- **빌드 시스템과 컴파일러 단위 차이**: 빌드 시스템(Xcode target / SwiftPM target)과 컴파일러(Swift module) 단위는 1:N일 수 있음. 매핑 메타를 보존해야 의미 있는 diff.
- **Sandbox**: macOS sandbox 안에서 컴파일러는 임시 디렉토리 외 쓰기 금지. 작업 디렉토리는 `$TMPDIR` 하위. 필요시 `-disable-sandbox`.
- **분석 vs 빌드 분리**: 분석 호출(`-typecheck` 등)은 오브젝트 산출 없이 끝나도록 — 빌드 캐시 오염 방지.

## 13. 입력 도메인

본 MCP가 받는 입력은 다음 6단계 중 하나로 정규화:

- **단일 파일** — `<file>.swift`
- **소스 디렉토리** — 같은 모듈 가정의 다중 파일
- **Swift 모듈** — `module-name` + search path 필요
- **SwiftPM 패키지** — `Package.swift`에서 타깃 정보 추출
- **Xcode 프로젝트** — `.xcodeproj` + target
- **Xcode 워크스페이스** — `.xcworkspace` + scheme

각 단계마다 컴파일러 호출 인자를 추출하는 경로가 다르므로, 도구 입력에서 단계를 명시.

## 14. Source URLs (보조)

1차 출처는 toolchain 바이너리 출력이며, 외부 URL은 보조용:

- https://www.swift.org/documentation/
- https://github.com/apple/swift/blob/main/include/swift/Basic/Statistic.h
- https://github.com/apple/swift/blob/main/docs/CompilerPerformance.md
- https://github.com/apple/swift/blob/main/docs/SIL/SIL.rst
- https://github.com/apple/swift/blob/main/docs/DependencyAnalysis.md
- https://github.com/apple/swift-docc-symbolkit
