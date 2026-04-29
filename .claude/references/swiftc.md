---
library: swiftc
version: "Apple Swift 6.3.1 (swiftlang-6.3.1.1.2 clang-2100.0.123.102), swift-driver 1.148.6"
collected: "2026-04-30"
target: arm64-apple-macosx26.0
toolchain_path: /Volumes/eyedisk/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
sources:
  - local-binary: "swiftc --help"
  - local-binary: "swiftc -help-hidden"
  - local-binary: "swiftc -frontend -help"
  - local-binary: "swiftc -frontend -help-hidden"
---

# swiftc — Swift Compiler CLI Reference

## Overview

`swiftc`는 Swift 컴파일러의 **드라이버(driver)**입니다. 사용자가 입력한 소스 파일과 옵션을 받아 내부적으로 다음을 오케스트레이션합니다.

1. **Frontend** 호출 (실제 파싱·타입체크·SILGen·IRGen·코드 생성). `swiftc -frontend ...` 또는 동등 바이너리 `swift-frontend`로 직접 호출 가능.
2. **Clang** 호출 (브리징 헤더·C 인터롭).
3. **Linker** 호출 (실행 파일/라이브러리 산출).

본 MCP가 호출하는 인터페이스 표준은 **driver(`swiftc`)** 이며, frontend-only 옵션이 필요하면 `-Xfrontend <opt>`로 패스스루합니다. LLVM-only 옵션은 `-Xllvm`, Clang은 `-Xcc`, Clang 링커는 `-Xclang-linker`, 시스템 링커는 `-Xlinker`.

## Source Authority

이 문서는 **로컬 toolchain 바이너리**의 자체 출력에서 생성되었습니다. `swift.org` 문서나 외부 자료보다 이 출력이 권위가 높습니다. Toolchain이 바뀌면 (예: Swift 6.4) 본 문서를 재생성해야 합니다.

```
swiftc --help              # public driver options
swiftc -help-hidden        # all driver options including hidden
swiftc -frontend -help     # public frontend options
swiftc -frontend -help-hidden  # all frontend options
swiftc -emit-supported-arguments out.json  # JSON dump of all supported args
```

`-emit-supported-arguments`는 머신 친화적 JSON으로 모든 인자를 덤프합니다 — MCP 도구 인자 검증에 활용 가능.

## Invocation Modes

| 호출 형태 | 의미 |
|---|---|
| `swiftc <files>` | 드라이버: 빌드 전체 (default = 실행 파일/오브젝트) |
| `swiftc -frontend <args>` | Frontend 직접 호출 (driver 우회) |
| `swift-frontend <args>` | 동등 — frontend 바이너리 직접 호출 |
| `swiftc --driver-mode=swift` | `swift` REPL/script 모드로 실행 |
| `swiftc --driver-mode=swiftc` | `swiftc` 컴파일 모드 (기본) |
| `swiftc -e '<code>'` | 인자로 받은 한 줄 코드 실행 |
| `swiftc -jit-build` (hidden) | JIT 컴파일 모드 |

## Driver Modes (`MODES`)

각 모드는 입력을 어떻게 처리할지 결정합니다. 동시에 둘 이상 지정 불가.

### Parsing / Type-checking only
- `-parse` — 입력 파싱만
- `-resolve-imports` — 파싱 + import 해석
- `-typecheck` — 파싱 + 타입체크
- `-dump-parse` — 파싱 후 AST 덤프 (raw)
- `-dump-ast` — 파싱 + 타입체크 후 AST 덤프
- `-print-ast` — 파싱 + 타입체크 후 AST를 pretty-print (선언 + 본문)
- `-print-ast-decl` — 같음, 선언만
- `-dump-scope-maps <expanded|line:col[,line:col]>` — 스코프 맵 덤프
- `-dump-type-info` — 임포트된 모듈의 fixed-size 타입 YAML 덤프
- `-dump-pcm` — precompiled Clang module 덤프
- `-dump-usr` — 선언 참조마다 USR 덤프
- `-emit-imported-modules` — 임포트된 모듈 리스트 출력
- `-scan-dependencies` — 의존성 스캔
- `-index-file` — 단일 소스 파일에 대한 인덱스 데이터 생산

### SIL / IR / Codegen
- `-emit-silgen` — raw SIL
- `-emit-sil` — canonical SIL (default 단계까지 최적화 후)
- `-emit-lowered-sil` — lowered SIL
- `-emit-sib` — serialized AST + canonical SIL (binary)
- `-emit-sibgen` — serialized AST + raw SIL (binary)
- `-emit-irgen` — LLVM IR (LLVM 최적화 전)
- `-emit-ir` — LLVM IR (LLVM 최적화 후)
- `-emit-bc` — LLVM bitcode
- `-emit-assembly` (=`-S`) — 어셈블리
- `-emit-object` (=`-c`) — 오브젝트 파일

### Linking products
- `-emit-executable` — 실행 파일 (driver default)
- `-emit-library` — 동적/정적 라이브러리 (`-static`과 함께 사용 시 정적)

### Module / metadata
- `-emit-module` — `.swiftmodule` 산출
- `-emit-pcm` — module map → 사전 컴파일된 Clang 모듈
- `-emit-supported-arguments` — 모든 지원 인자를 JSON으로 덤프
- `-merge-modules` (frontend only) — 입력 모듈들을 머지

## Driver Options — by Category

### Output paths

- `-o <file>` — 출력 파일 경로
- `-output-file-map <path>` — 입출력 매핑 파일 (incremental 빌드용)
- `-ir-output-dir <dir>` — 컴파일 부산물로 LLVM IR 추가 출력
- `-sil-output-dir <dir>` — SIL 추가 출력
- `-emit-dependencies` — Make 호환 의존성 파일 출력

### Module emission

- `-emit-module` / `-emit-module-path <path>` — `.swiftmodule` 출력
- `-emit-module-interface` / `-emit-module-interface-path <path>` — `.swiftinterface` 출력
- `-emit-private-module-interface-path <path>` (hidden)
- `-emit-package-module-interface-path <path>` (hidden)
- `-emit-module-source-info-path <path>` — 소스 정보 파일
- `-emit-module-summary` / `-emit-module-summary-path <path>`
- `-emit-module-dependencies-path <path>`
- `-emit-module-serialize-diagnostics-path <path>`
- `-emit-objc-header` / `-emit-objc-header-path <path>` — ObjC 헤더 생성
- `-emit-clang-header-min-access <level>` — 헤더에 포함할 최소 접근 수준
- `-emit-clang-header-nonmodular-includes` — 모듈 import를 textual import로 보강
- `-emit-tbd` / `-emit-tbd-path <path>` — TBD 파일
- `-emit-api-descriptor` / `-emit-api-descriptor-path <path>` — 모듈 API JSON
- `-emit-loaded-module-trace` / `-emit-loaded-module-trace-path <path>`
- `-emit-digester-baseline` / `-emit-digester-baseline-path <path>` — API digester 기준선
- `-emit-localized-strings` / `-emit-localized-strings-path <path>` (hidden)
- `-emit-const-values-path <path>` — 컴파일 타임 알려진 값 추출
- `-emit-extension-block-symbols` / `-omit-extension-block-symbols` (hidden) — 심볼 그래프에서 extension 처리
- `-emit-symbol-graph` / `-emit-symbol-graph-dir <dir>` (hidden)
- `-emit-fine-grained-dependency-sourcefile-dot-files` (hidden)
- `-emit-variant-module-path <path>` — 변형 타깃 모듈
- `-emit-variant-module-source-info-path`
- `-emit-variant-module-interface-path`
- `-emit-variant-private-module-interface-path`
- `-emit-variant-package-module-interface-path`
- `-emit-variant-api-descriptor-path`
- `-experimental-emit-variant-module` — variant + primary 두 모듈 동시 산출
- `-no-verify-emitted-module-interface` / `-verify-emitted-module-interface`
- `-no-emit-module-separately` / `-emit-module-separately-wmo` / `-no-emit-module-separately-wmo` (hidden)
- `-experimental-emit-module-separately` (hidden)
- `-avoid-emit-module-source-info`
- `-embed-tbd-for-module <module>`

### Optimization

- `-Onone` — 최적화 없음 (debug 기본)
- `-O` — 최적화 활성
- `-Osize` — 코드 크기 최적화
- `-Ounchecked` — 최적화 + 런타임 안전 검사 제거
- `-Oplayground` (hidden) — playground용 최적화
- `-whole-module-optimization` / `-no-whole-module-optimization` — WMO
- `-package-cmo` — 패키지 경계 내 cross-module optimization
- `-experimental-package-cmo` — deprecated alias
- `-experimental-package-cmo-abort-on-deserialization-fail`
- `-cross-module-optimization` (hidden) — 일반 CMO
- `-enable-cmo-everything` (hidden) — 모든 API에 CMO (Embedded Swift 수준)
- `-enable-default-cmo` (hidden) — conservative CMO
- `-disable-cmo` (hidden)
- `-experimental-hermetic-seal-at-link` (hidden) — 클라이언트 모두 link-time visible로 가정
- `-lto=<llvm-thin|llvm-full>` — LTO 활성
- `-lto-library <path>` — 사용할 LTO 라이브러리
- `-load-pass-plugin=<path>` — LLVM pass 플러그인 로드
- `-remove-runtime-asserts` — 런타임 안전 검사 제거 (Ounchecked의 부분 효과)

### Debug info

- `-g` — 디버그 정보 (LLDB 권장 기본)
- `-gnone` — 디버그 정보 없음
- `-gline-tables-only` — backtrace용 최소 정보
- `-gdwarf-types` — full DWARF type info
- `-debug-info-format=<dwarf|codeview>`
- `-dwarf-version=<n>` — DWARF 버전 지정
- `-debug-prefix-map <prefix=replacement>` — 디버그 정보 경로 재매핑
- `-coverage-prefix-map <prefix=replacement>`
- `-file-prefix-map <prefix=replacement>` — 디버그 + 커버리지 + 인덱스 모두 재매핑
- `-file-compilation-dir <path>` — 디버그 정보에 임베드할 컴파일 디렉토리
- `-debug-info-store-invocation` — 컴파일러 호출을 디버그 정보에 임베드
- `-debug-info-for-profiling` — 샘플링 기반 프로파일링용 추가 정보
- `-debug-module-path <path>` — 모듈 바이너리 경로 (디버그 정보 요구)
- `-prefix-serialized-debugging-options` — `.swiftmodule` 직렬 디버그 정보에 prefix 매핑 적용
- `-experimental-serialize-debug-info` (hidden) — debug scope 직렬화
- `-verify-debug-info` — 디버그 출력의 바이너리 표현 검증

### Diagnostics & reporting

- `-color-diagnostics` / `-no-color-diagnostics`
- `-diagnostic-style <swift|llvm>`
- `-fixit-all` — 필터링 없이 모든 fix-it 적용
- `-locale <code>` / `-localization-path <path>` — 진단 메시지 언어
- `-print-educational-notes` — 진단 출력에 교육 노트 포함
- `-print-diagnostic-groups` (hidden) — 진단 그룹 표시
- `-debug-diagnostic-names` (hidden) — 진단 이름 표시
- `-serialize-diagnostics` — 바이너리 진단 파일
- `-suppress-notes` / `-suppress-warnings` / `-suppress-remarks`
- `-warnings-as-errors` / `-no-warnings-as-errors`
- `-Werror <diagnostic_group>` (hidden) — 그룹별로 warning→error
- `-Wwarning <diagnostic_group>` (hidden) — 그룹별로 warning 유지 강제
- `-warn-concurrency` — 미래 언어 버전에서 ill-formed가 될 코드 경고
- `-warn-implicit-overrides` — 프로토콜 멤버 묵시적 오버라이드 경고
- `-warn-soft-deprecated` (hidden)
- `-warn-swift3-objc-inference-complete` / `-warn-swift3-objc-inference-minimal` (hidden, deprecated)
- `-typo-correction-limit <n>` (hidden) — 오타 수정 시도 횟수 상한
- `-Rcache-compile-job` — 컴파일러 캐싱 remark
- `-Rcross-import` — cross-import 트리거 시 remark
- `-Rindexing-system-module` — 시스템 모듈 인덱싱 시 remark
- `-Rmacro-loading` — 매크로 로딩 remark
- `-Rmodule-api-import` — API에 기여한 import bridging remark
- `-Rmodule-loading` — 모듈 로드 remark
- `-Rmodule-recovery` — 로드된 모듈 컨텍스트 불일치 remark
- `-Rmodule-serialization` — 모듈 직렬화 remark
- `-Rpass=<regex>` / `-Rpass-missed=<regex>` — 최적화 패스 보고
- `-Rskip-explicit-interface-build`

### Optimization-record output
- `-save-optimization-record` — YAML 최적화 기록
- `-save-optimization-record=<format>`
- `-save-optimization-record-path <file>`
- `-save-optimization-record-passes <regex>`

### Module / Package metadata

- `-module-name <name>` — 빌드할 모듈 이름
- `-module-abi-name <name>` — 모듈 콘텐츠의 ABI 이름
- `-module-alias <alias=real>` — 소스에서의 alias 이름 → 실제 모듈 매핑
- `-module-cache-path <path>` — Clang/Swift 모듈 캐시 경로
- `-module-link-name <name>` — 자동 link 시 사용할 라이브러리 이름
- `-package-name <name>` — 모듈이 속한 패키지 이름
- `-package-description-version <vers>` (hidden) — `PackageDescription` availability 평가용
- `-project-name <name>` — 모듈이 속한 프로젝트 이름
- `-public-module-name <name>` — 진단/문서에 공개될 모듈명
- `-export-as <name>` — 클라이언트 모듈 인터페이스에서 참조될 모듈 이름
- `-allowable-client <vers>` — 이 모듈을 import 허용할 모듈명
- `-enable-private-imports` (hidden) — internal/private API 접근 허용
- `-enable-testing` (hidden) — 테스트용 internal API 접근
- `-library-level <api|spi|other>` (hidden) — 라이브러리 배포 레벨
- `-interface-compiler-version <vers>` (hidden) — `.swiftinterface` 생성 컴파일러 버전 명시
- `-register-module-dependency <name>` — frontend import 없이 의존성 스캔 등록만
- `-allow-non-resilient-access` — exportable 외 모든 콘텐츠를 binary 모듈에 생성
- `-experimental-allow-non-resilient-access` — deprecated alias
- `-experimental-package-bypass-resilience` — deprecated, no-op
- `-experimental-package-interface-load` (hidden) — 같은 패키지면 패키지 interface 로드 허용
- `-min-runtime-version <ver>` (hidden) — non-Darwin에서 최소 런타임 강제
- `-min-swift-runtime-version <vers>` — 런타임에서 사용 가능한 최소 Swift 런타임 버전
- `-runtime-compatibility-version <ver|none>` — 호환 라이브러리 링크
- `-user-module-version <vers>` — 모듈 작성자가 명시한 모듈 버전
- `-experimental-skip-non-inlinable-function-bodies` (hidden) — non-inlinable 함수 본문 type-check/SILGen 건너뛰기
- `-experimental-skip-non-inlinable-function-bodies-without-types` (hidden)

### Bridging headers / PCH

- `-import-bridging-header <path>` — C 헤더 묵시 import
- `-internal-import-bridging-header <path>` — 같음, internal import로
- `-import-pch <path>` (hidden) — PCH 직접 import
- `-internal-import-pch <path>` (hidden)
- `-import-underlying-module` — 모듈의 ObjC 절반 묵시 import
- `-enable-bridging-pch` / `-disable-bridging-pch` (hidden) — bridging PCH 자동 생성
- `-auto-bridging-header-chaining` / `-no-auto-bridging-header-chaining` (hidden)
- `-pch-output-dir <path>` (hidden) — 자동 생성된 PCH 영구 보관 위치

### Search paths

- `-I <dir>` / `-Isystem <dir>` — Swift 모듈 import 검색 경로
- `-F <dir>` / `-Fsystem <dir>` — 프레임워크 검색 경로
- `-L <dir>` — 라이브러리 링크 검색 경로
- `-l <name>` — 링크할 라이브러리
- `-framework <name>` — 링크할 프레임워크
- `-vfsoverlay <file>` — VFS overlay 파일 추가
- `-nostdimport` — stdlib + toolchain import 경로 검색 안 함
- `-nostdlibimport` — stdlib import 경로만 검색 안 함
- `-resource-dir <dir>` (hidden) — 컴파일러 리소스 위치 (예: `/usr/lib/swift`)

### Linking

- `-static` — 정적 링크 가능 모듈로 빌드 (`-emit-library`와 함께 정적 라이브러리)
- `-static-executable` / `-no-static-executable` (hidden) — 실행 파일 정적 링크
- `-static-stdlib` / `-no-static-stdlib` (hidden) — stdlib 정적 링크
- `-no-stdlib-rpath` (hidden) — rpath 추가 없음
- `-toolchain-stdlib-rpath` / `-no-toolchain-stdlib-rpath` (hidden)
- `-nostartfiles` (hidden) — Swift 언어 startup 루틴 링크 안 함
- `-tools-directory <dir>` — 외부 실행 파일 (ld, clang) 검색 경로
- `-gcc-toolchain <path>` (hidden)
- `-use-ld=<flavor>` — 링커 종류
- `-ld-path=<path>` (hidden) — 링커 절대 경로
- `-build-id <id>` — 링커에 build-id 전달
- `-Xlinker <arg>` — 시스템 링커에 인자 전달
- `-Xclang-linker <arg>` (hidden) — Clang이 링킹할 때 전달
- `-autolink-force-load` (hidden) — 사용 심볼 없어도 강제 link
- `-disable-autolinking-runtime-compatibility` — 런타임 호환 라이브러리 autolink 비활성
- `-disable-autolinking-runtime-compatibility-concurrency`
- `-disable-autolinking-runtime-compatibility-dynamic-replacements`
- `-enable-autolinking-runtime-compatibility-bytecode-layouts`
- `-link-objc-runtime` / `-no-link-objc-runtime` (hidden, deprecated)

### Sanitizers

- `-sanitize=<check>` — 런타임 검사 활성 (예: `address`, `thread`, `undefined`, `fuzzer`, `scudo`)
- `-sanitize-recover=<check>` — 에러 복구 가능한 sanitizer 검사
- `-sanitize-coverage=<type>` — sanitizer + coverage 타입
- `-sanitize-stable-abi` — stable ABI sanitizer 라이브러리 링크
- `-sanitize-address-use-odr-indicator` (hidden) — ASan ODR indicator

### Profiling / PGO / Coverage

- `-profile-generate` — 실행 카운트 수집 instrumentation
- `-profile-coverage-mapping` — 커버리지 매핑 데이터
- `-profile-use=<profdata>` — PGO profdata 사용
- `-profile-sample-use=<profdata>` — 샘플링 PGO
- `-ir-profile-generate` / `-ir-profile-generate=<dir>` — IR-level instrumentation
- `-cs-profile-generate` / `-cs-profile-generate=<dir>` — context-sensitive
- `-ir-profile-use=<profdata>` — IR-level profdata
- `-profile-stats-entities` (hidden) — `-stats-output-dir` 변화 프로파일 (소스 엔티티별)
- `-profile-stats-events` (hidden) — `-stats-output-dir` 이벤트 프로파일

### Caching / CAS

- `-cache-compile-job` — 컴파일러 캐싱 활성
- `-cache-disable-replay` — 캐시에서 결과 로드 건너뛰기
- `-cas-path <path>` — CAS 경로
- `-cas-plugin-path <path>` / `-cas-plugin-option <name>=<opt>`

### Concurrency / Memory safety

- `-strict-concurrency=<minimal|targeted|complete>` — Sendable·격리 검사 강도
- `-warn-concurrency` — Concurrency 모델 위반 경고
- `-enable-actor-data-race-checks` / `-disable-actor-data-race-checks` — 런타임 race 검사
- `-disable-dynamic-actor-isolation` — 동적 actor 격리 검사 비활성
- `-default-isolation MainActor|nonisolated` — 기본 actor 격리 (default: nonisolated)
- `-strict-memory-safety` — 엄격한 메모리 안전 검사
- `-strict-memory-safety:migrate` — 마이그레이션 모드
- `-no-allocations` (hidden) — 힙 할당이 필요한 코드(클래스/클로저 등) 진단

### Plugins / Macros

- `-plugin-path <dir>` — 플러그인 검색 경로
- `-external-plugin-path <dir>#<plugin-server-path>` — 플러그인 서버와 함께
- `-load-plugin-executable <path>#<module-names>` — 매크로 실행 플러그인
- `-load-plugin-library <path>` — 매크로 동적 라이브러리
- `-load-resolved-plugin <lib>#<exec>#<modules>` — 해석된 플러그인 구성
- `-in-process-plugin-server-path <path>` — in-process 플러그인 서버
- `-Rmacro-loading` — 매크로 로드 remark

### Indexing

- `-index-file` — 단일 파일에 대한 인덱스 데이터 생산 모드
- `-index-file-path <path>` — 인덱싱 대상 파일
- `-index-store-path <path>` — 인덱스 데이터 저장 위치
- `-index-store-compress` — 인덱스 압축
- `-index-ignore-clang-modules` — Clang 모듈 인덱싱 제외
- `-index-ignore-system-modules` — 시스템 모듈 인덱싱 제외
- `-index-include-locals` — 로컬 정의/참조 포함
- `-index-unit-output-path <path>` — 인덱스 데이터의 출력 경로

### Symbol graph

- `-emit-symbol-graph` (hidden)
- `-emit-symbol-graph-dir <dir>` (hidden)
- `-symbol-graph-allow-availability-platforms <plats>` (hidden)
- `-symbol-graph-block-availability-platforms <plats>` (hidden)
- `-symbol-graph-minimum-access-level <level>` (hidden)
- `-symbol-graph-pretty-print` (hidden)
- `-symbol-graph-skip-inherited-docs` (hidden)
- `-symbol-graph-skip-synthesized-members` (hidden)
- `-include-spi-symbols` (hidden) — SPI 심볼 포함
- `-skip-inherited-docs` (hidden)
- `-skip-protocol-implementations` (hidden)
- `-emit-extension-block-symbols` / `-omit-extension-block-symbols` (hidden)

### Target / SDK / Availability

- `-target <triple>` — 타깃 삼중체 (예: `arm64-apple-macos14`, `x86_64-apple-ios18.0-simulator`)
- `-target-cpu <name>` — 특정 CPU variant
- `-target-arch-variant <variant>` — fat 바이너리 추가 슬라이스
- `-target-min-inlining-version <vers>` — `@available` 없는 inlinable 코드의 back-deploy 최소 버전
- `-target-variant <triple>` — macCatalyst 'zippered' 추가 변형 타깃
- `-clang-target <triple>` — 내부 Clang에 별도 타깃 지정
- `-clang-target-variant <triple>` — Clang variant
- `-disable-clang-target` — Clang 별도 타깃 비활성
- `-sdk <path>` — SDK 경로
- `-sysroot <path>` — Native 플랫폼 sysroot
- `-sdk-module-cache-path <path>` — SDK 모듈 캐시
- `-allow-availability-platforms <plats>` — availability 메타데이터 제한
- `-block-availability-platforms <plats>` — symbol graph availability에서 제외
- `-define-availability <macro>` — `'macroName : iOS 13.0, macOS 10.15'` 매크로 정의
- `-define-always-enabled-availability-domain <name>` (hidden) — 모든 배포에서 사용 가능한 도메인
- `-define-disabled-availability-domain <name>` (hidden) — 컴파일 타임 비활성
- `-define-dynamic-availability-domain <name>` (hidden) — 런타임 토글
- `-define-enabled-availability-domain <name>` (hidden) — 컴파일 타임 활성
- `-require-explicit-availability` — 공개 선언에 availability 강제 (warn)
- `-require-explicit-availability=<error|warn|ignore>`
- `-require-explicit-availability-target <target>` — fix-it 제안용 타깃
- `-require-explicit-sendable` — 공개 선언에 Sendable 명시 강제
- `-unavailable-decl-optimization=<none|complete>` — unavailable 선언 코드 생성 정책
- `-windows-sdk-root <path>` / `-windows-sdk-version <vers>`
- `-visualc-tools-root <path>` / `-visualc-tools-version <vers>`
- `-libc <value>` — libc 런타임 라이브러리

### Dependency scanning

- `-scan-dependencies` (mode) — 의존성 스캔
- `-explicit-module-build` (hidden) — 모듈 의존성 사전 빌드
- `-explicit-auto-linking` — 모든 link 의존성을 링커 호출에 명시 (`-explicit-module-build` 필요)
- `-explicit-dependency-graph-format=<json|dot>` (hidden)
- `-print-explicit-dependency-graph` (hidden)
- `-print-preprocessed-explicit-dependency-graph` (hidden)
- `-incremental-dependency-scan` (hidden) — 이전 스캔 산출물 재사용/검증
- `-explain-module-dependency <name>` — 특정 모듈 의존 이유 remark
- `-explain-module-dependency-detailed <name>` — 모든 경로
- `-clang-scanner-module-cache-path <path>`
- `-scanner-prefix-map <prefix=replacement>`
- `-scanner-prefix-map-paths <prefix> <replacement>`
- `-scanner-prefix-map-sdk <path>`
- `-scanner-prefix-map-toolchain <path>`
- `-clang-build-session-file <path>` — 빌드 세션 타임스탬프
- `-validate-clang-modules-once` — 세션 내 1회 검증
- `-nonlib-dependency-scanner` (hidden) — 라이브러리 대신 `swift-frontend -scan-dependencies` 사용
- `-dependency-scan-serialize-diagnostics-path <path>`
- `-track-system-dependencies` — Make-style 의존성에 시스템 의존성 포함

### Driver internals (대부분 hidden)

- `--driver-mode=<swift|swiftc>` (hidden)
- `-driver-print-actions` (hidden) — 액션 리스트 덤프
- `-driver-print-bindings` (hidden) — job 입출력 덤프
- `-driver-print-jobs` (hidden) — job 리스트 덤프
- `-driver-print-graphviz` (hidden) — job 그래프 graphviz
- `-driver-print-output-file-map` (hidden)
- `-driver-print-derived-output-file-map` (hidden)
- `-driver-show-incremental` (hidden) — 재빌드 사유 (with `-v`)
- `-driver-show-job-lifecycle` (hidden)
- `-driver-skip-execution` (hidden)
- `-driver-time-compilation` — 컴파일 작업 총 시간
- `-driver-batch-count <n>` (hidden) / `-driver-batch-seed <n>` / `-driver-batch-size-limit <n>`
- `-driver-emit-fine-grained-dependency-dot-file-after-every-import` (hidden)
- `-driver-filelist-threshold <n>` (hidden) — filelist로 전환 임계
- `-driver-force-response-files` (hidden) — 테스트용
- `-driver-use-filelists` (hidden) — 가능하면 filelist 사용
- `-driver-use-frontend-path <path>` (hidden) — frontend 실행 파일 강제 (`;` 구분 인자)
- `-driver-warn-unused-options` (hidden)
- `-driver-always-rebuild-dependents` (hidden)
- `-driver-verify-fine-grained-dependency-graph-after-every-import` (hidden)
- `-disable-batch-mode` / `-enable-batch-mode` (hidden)
- `-incremental` (hidden) — 가능 시 incremental 빌드
- `-disable-incremental-imports` / `-enable-incremental-imports`
- `-disable-incremental-file-hashing` / `-enable-incremental-file-hashing`
- `-disable-only-one-dependency-file` / `-enable-only-one-dependency-file`
- `-disallow-use-new-driver` — 새 swift-driver 비활성
- `-use-frontend-parseable-output` (hidden) — driver 대신 frontend가 parseable-output
- `-parseable-output` — 파싱 가능 형식의 텍스트 출력
- `-disable-sandbox` — 서브프로세스 sandbox 비활성
- `-save-temps` (hidden) — 중간 산출물 보존
- `-fine-grained-timers` (hidden)
- `-stats-output-dir <dir>` (hidden)
- `-trace-stats-events` (hidden)
- `-print-zero-stats` (hidden)
- `-emit-fine-grained-dependency-sourcefile-dot-files` (hidden)
- `-verify-incremental-dependencies` (hidden)
- `-j <n>` — 병렬 명령 수
- `-num-threads <n>` — 멀티스레드 활성 + 스레드 수
- `-v` — verbose, 실행 명령 표시
- `-version` / `-help` / `-help-hidden`
- `-emit-supported-arguments` — 지원 인자 JSON 덤프
- `-print-target-info` — 타깃 정보 출력
- `-print-static-build-config` — `#if` 평가용 정적 빌드 구성
- `-print-supported-features` — 지원 feature 출력

### Language version / Features / Migration

- `-swift-version <vers>` — 입력을 특정 Swift 언어 버전으로 해석 (예: `5`, `6`)
- `-enable-experimental-feature <name>` — 실험 기능 활성
- `-disable-experimental-feature <name>`
- `-enable-upcoming-feature <name>` — 다음 언어 버전 도입 예정 기능 미리 활성
- `-disable-upcoming-feature <name>`
- `-enable-bare-slash-regex` — `/regex/` 정규식 리터럴 활성
- `-enable-builtin-module` — `Builtin` 명시 import 허용
- `-enable-experimental-additive-arithmetic-derivation`
- `-enable-experimental-concise-pound-file`
- `-enable-experimental-forward-mode-differentiation` — 전방 미분
- `-enforce-exclusivity=<enforcement>` — 배타성 법칙 강제
- `-experimental-c-foreign-reference-types` (hidden, deprecated)
- `-experimental-clang-importer-direct-cc1-scan` (hidden)
- `-experimental-performance-annotations` (hidden, deprecated)
- `-experimental-package-bypass-resilience` (deprecated)
- `-experimental-skip-non-inlinable-function-bodies` (hidden)
- `-experimental-skip-non-inlinable-function-bodies-without-types` (hidden)
- `-cxx-interoperability-mode=<default|off>` — C++ 인터롭
- `-D <name>` — 조건부 컴파일 플래그 활성
- `-application-extension` — App Extension용 코드만 허용
- `-application-extension-library` — App Extension Library용
- `-parse-as-library` — 입력을 스크립트가 아니라 라이브러리로 파싱
- `-parse-sil` — 입력을 SIL 코드로 파싱
- `-parse-stdlib` (hidden) — stdlib으로 파싱
- `-e <code>` — 명령행 코드 한 줄 실행
- `-fixit-all` — 모든 fix-it 자동 적용
- `-update-code` (hidden) — Swift 코드 업데이트
- `-migrate-keep-objc-visibility` — 마이그레이션 시 Swift 3 묵시 가시성에 `@objc` 추가
- `-disable-migrator-fixits` — 마이그레이터 fix-it 자동 적용 비활성
- `-dump-migration-states-dir <path>` — 마이그레이션 입출력 + 상태 덤프
- `-migrator-update-sdk` / `-migrator-update-swift` — Xcode 호환용 no-op

### API digester

- `-compare-to-baseline-path <path>` — baseline과 API 비교, breaking change 진단
- `-emit-digester-baseline` / `-emit-digester-baseline-path <path>`
- `-digester-mode <api|abi>`
- `-digester-breakage-allowlist-path <path>`
- `-serialize-breaking-changes-path <path>`

### Embedded bitcode (legacy)

- `-embed-bitcode` — bitcode를 데이터로 embed
- `-embed-bitcode-marker` — placeholder

### Misc / compatibility

- `-assert-config <Debug|Release|Unchecked|DisableReplacement>` — `assert_configuration` 치환
- `-compiler-assertions` — 컴파일러 self-check 활성
- `-enable-deterministic-check` — 같은 입력으로 두 번 실행해 결정성 확인
- `-print-static-build-config`
- `-pretty-print` — JSON 출력 pretty-print
- `-export-as <name>`
- `-no-stack-check` / `-stack-check` (hidden)
- `-no-sign-class-ro` / `-sign-class-ro` (hidden) — `class_ro_t` 포인터 인증
- `-swift-ptrauth-mode <mode>` — `LegacyAndStrip|NewAndStrip|NewAndAuth`
- `-no-strict-implicit-module-context` / `-strict-implicit-module-context` (hidden)
- `-solver-shrink-unsolved-threshold <n>` (hidden)
- `-value-recursion-threshold <n>` (hidden)
- `-typo-correction-limit <n>` (hidden)
- `-access-notes-path <yaml>` — Swift 선언 attribute 오버라이드 YAML
- `-api-diff-data-dir <path>` / `-api-diff-data-file <path>`
- `-blocklist-file <path>` (frontend; driver passthrough via `-Xfrontend`) — blocklist 구성
- `-working-directory <path>` — 파일 경로 해석 기준 디렉토리
- `-Xcc <arg>` — Clang에 전달
- `-Xfrontend <arg>` — Frontend에 전달
- `-Xllvm <arg>` — LLVM에 전달
- `-Xclang-linker <arg>` (hidden)
- `-Xlinker <arg>`

## Frontend Mode (`-frontend` / `swift-frontend`)

Frontend는 driver의 jobs를 실제로 수행하는 단일 컴파일 단위 처리기입니다. 일반 사용자는 직접 호출하지 않지만, MCP에서 정밀한 제어가 필요할 때 사용합니다.

### Frontend-specific modes (driver에는 없는 것 위주)

- `-merge-modules` — 입력 모듈들을 머지만

### Frontend-only / 주요 옵션 그룹

(driver와 겹치지 않는 또는 frontend에서만 의미가 있는 항목 — 전체 1329줄 dump가 필요한 경우 `swiftc -frontend -help-hidden` 직접 실행)

- `-primary-file <path>` — primary 파일 지정 (batch 모드)
- `-primary-filelist <path>` — primary 파일 리스트
- `-supplementary-output-file-map <path>` — 보조 출력 매핑
- `-output-filelist <path>` / `-output-file-map <path>`
- `-emit-pch` (frontend mode) — PCH 산출
- `-emit-reference-dependencies-path <path>` — incremental용 reference deps
- `-emit-fixits-path <path>` — fix-it 직렬화
- `-cas-backend` / `-cas-backend-mode=<native|casid|verify>` / `-cas-emit-casid-file`
- `-const-gather-protocols-file <path>` — const 값 추출 대상 프로토콜 목록
- `-cache-replay-prefix-map <prefix> <replacement>`
- `-autolink-library <name>` — 의존 라이브러리 추가
- `-backup-module-interface-path <dir>` — SDK 인터페이스의 백업 위치
- `-blocklist-file <path>` — blocklist 구성
- `-bridging-header-pch-key <key>`
- `-bypass-resilience-checks`
- `-debug-assert-after-parse`
- `-debug-assert-immediately`
- `-debug-cycles`
- `-debug-forbid-typecheck-prefix <prefix>`
- `-debug-generic-signatures`
- `-debug-time-compilation` / `-debug-time-expression-type-checking` / `-debug-time-function-bodies`
- `-disable-arc-opts` / `-disable-ossa-opts` / `-disable-sil-perf-optzns`
- `-dump-clang-diagnostics`
- `-dump-clang-lookup-tables`
- `-dump-interface-hash`
- `-emit-extension-block-symbols`
- `-emit-pch`
- `-experimental-print-full-convention`
- `-import-module <name>` — 명시 import
- `-import-objc-header <path>` — driver의 `-import-bridging-header`와 동등
- `-interpret` — `swift` 명령처럼 입력 해석 실행 (frontend 단독)
- `-i` — interpret 단축
- `-num-threads <n>` — 별도 의미 (frontend는 다중 출력 시 사용)
- `-output-request-graphviz <path>` — request graph
- `-package-cmo`
- `-print-llvm-inline-tree`
- `-print-stats`
- `-stats-output-dir`
- `-Rmodule-recovery` (frontend에서도 적용)
- `-target-sdk-name <name>` / `-target-sdk-version <vers>` (frontend) — SDK 정보 명시
- `-tbd-compatibility-version <vers>` / `-tbd-current-version <vers>` / `-tbd-install_name <name>`
- `-track-stat-allocations` / `-trace-stats-events`
- `-warn-on-editor-placeholder`

> 1329줄짜리 frontend hidden dump 전체는 본 문서에 동봉하지 않았습니다. 정밀 제어 시 `swiftc -frontend -help-hidden`을 그 자리에서 실행하여 현재 toolchain의 정확한 옵션을 확인하세요.

## Practical Recipes (본 MCP가 노출할 도구의 호출 형태)

### 1) AST 추출

```sh
swiftc -dump-ast -dump-ast-format json <file.swift>          # JSON
swiftc -dump-ast <file.swift>                                 # 텍스트
swiftc -print-ast <file.swift>                                # pretty-print
```

JSON은 컴파일러 버전 간 안정성 보장 없음 (`-help` 명시).

### 2) SIL 추출

```sh
swiftc -emit-silgen <file.swift>          # raw SIL (최적화 전)
swiftc -emit-sil    <file.swift>          # canonical SIL (mandatory passes 후)
swiftc -emit-sil -O <file.swift>          # 최적화된 SIL
swiftc -emit-lowered-sil <file.swift>     # lowered SIL (IRGen 직전)
swiftc -emit-sib    -o out.sib <file.swift>  # 직렬화 + canonical SIL (binary)
```

### 3) LLVM IR / bitcode

```sh
swiftc -emit-irgen <file.swift>           # LLVM 최적화 전
swiftc -emit-ir    <file.swift>           # LLVM 최적화 후
swiftc -emit-bc -o out.bc <file.swift>    # bitcode
swiftc -emit-assembly <file.swift>        # 어셈블리
```

### 4) 타입체크만

```sh
swiftc -typecheck <file.swift>            # 진단만
swiftc -resolve-imports <file.swift>      # import 해석까지
swiftc -parse <file.swift>                # 파싱만
```

### 5) 모듈 인터페이스 / 심볼 그래프

```sh
swiftc -emit-module -emit-module-interface -module-name M <files...>
swiftc -emit-symbol-graph -emit-symbol-graph-dir out/ -module-name M <files...>
swiftc -emit-api-descriptor-path api.json -module-name M <files...>
```

### 6) 의존성 스캔

```sh
swiftc -scan-dependencies <file.swift>
swiftc -scan-dependencies -explicit-module-build <file.swift>
```

### 7) 진단 친화 출력

```sh
swiftc -typecheck -diagnostic-style llvm -no-color-diagnostics -print-diagnostic-groups <file.swift>
swiftc -typecheck -serialize-diagnostics -emit-module-serialize-diagnostics-path d.dia <file.swift>
swiftc -emit-supported-arguments args.json   # 모든 지원 인자 JSON
```

### 8) 타깃 정보 / 정적 빌드 구성 / 지원 feature

```sh
swiftc -print-target-info -target arm64-apple-macos14
swiftc -print-static-build-config -target arm64-apple-ios18.0-simulator
swiftc -print-supported-features
```

### 9) Frontend 직접 호출 (driver 우회)

```sh
swiftc -frontend -emit-sil <file.swift> -module-name M -primary-file <file.swift>
swift-frontend -emit-ir <file.swift> -module-name M -o out.ll
```

### 10) Playground / 한 줄 실행

```sh
swiftc -e 'print("hello")'                # 한 줄 코드 실행
swift -frontend -interpret <file.swift>   # interpret 모드
swift <file.swift>                        # script 실행 (driver --driver-mode=swift)
```

## Common Pitfalls

- **AST JSON 포맷 안정성 없음.** `--help`가 명시: "no format is guaranteed stable across different compiler versions". 본 MCP가 AST를 외부에 노출할 때 주의.
- **`-emit-sil` 단독 실행은 엔트리포인트가 없으면 실패할 수 있음.** Top-level 코드/`@main`이 없는 라이브러리 파일은 `-parse-as-library`를 같이 사용.
- **`-O`/`-Onone`이 SIL 출력에 영향.** 최적화 단계에 따라 SIL이 달라지므로, 본 MCP는 최적화 수준을 명시적으로 받아 호출하는 것이 권장.
- **`-target` 미지정 시 host 기본값.** iOS/watchOS/tvOS/visionOS SDK를 사용하려면 `-sdk`와 `-target` 둘 다 필요. `xcrun -sdk iphoneos --show-sdk-path` 등으로 SDK 경로 해석.
- **`swiftc -frontend ...` 호출 시 `-primary-file`이 필수**일 수 있음 (multi-input + single-output 산출 모드들). Driver는 자동으로 처리.
- **`-Xfrontend` vs `-Xllvm` vs `-Xcc` vs `-Xlinker` vs `-Xclang-linker`** 혼동 주의 — 각각 다른 백엔드에 인자가 전달됨.
- **Sandbox.** macOS에서 컴파일러는 sandbox로 실행됨. 임시 디렉토리 외부 쓰기가 막힐 수 있어, MCP 임시 작업 디렉토리는 sandbox 친화적으로 둘 것. 필요시 `-disable-sandbox`.
- **`-help-hidden`의 옵션은 비공개/실험적/내부용.** 본 MCP가 외부에 노출할 옵션 화이트리스트는 `--help` 기준이 안전. hidden은 "내부 디버깅 / 고급 사용자"에 한정.
- **`-emit-supported-arguments`로 동적 검증 가능.** 본 MCP의 인자 검증을 toolchain 출력에 위임하면 toolchain 업그레이드에 자동 적응.

## Source URLs

본 문서는 외부 URL을 출처로 두지 않습니다. 1차 출처는 모두 로컬 toolchain 바이너리 출력입니다.

보조 참고 (사용 시 toolchain 출력과 충돌하면 toolchain 출력이 우선):
- https://www.swift.org/documentation/
- https://github.com/apple/swift/blob/main/include/swift/Option/Options.td  ← 옵션의 ground-truth 정의
- https://github.com/apple/swift/tree/main/docs

> `Options.td`는 swiftc의 모든 옵션이 선언된 LLVM TableGen 파일이며, `--help` 출력은 이 파일에서 생성됩니다. 옵션의 정확한 의미·타입·alias 관계가 필요하면 이 파일을 참조하세요.
