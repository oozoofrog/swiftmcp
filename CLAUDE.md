# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 정체성

**Swift Compiler MCP 서버**입니다. Swift 코드(타깃: macOS / iOS / iPadOS / watchOS / tvOS / visionOS / simulator 변형 / macCatalyst)에 대해 다음 능력을 MCP 도구로 노출합니다.

- 정적 분석 (type-check 시간, 의존성, 호출 그래프, API 표면, breaking change, concurrency·memory·availability 감사)
- AST / SIL / IR / 모듈 인터페이스 / 심볼 그래프 산출물 생성
- 격리 코드셋 빌드·실행 (외부 의존을 제거한 슬라이스 + 클라이언트 보강 루프)

본 MCP는 **시스템에 설치된 Swift 컴파일러 바이너리**를 외부 프로세스로 호출하여 결과를 회수합니다. 컴파일러 라이브러리를 임베드하거나 Swift 소스 트리(`apple/swift`)를 참조하지 않습니다.

## 형태와 결정 사항

- 진입점: **`mcpswx`** (Swift Package Manager executable). 이름은 사전 합의(`.claude/settings.local.json`).
- 코어 로직은 **`SwiftcMCPCore` 라이브러리 타깃**에 둔다. 진입점은 라이브러리의 얇은 어댑터.
- MCP 라이브러리: [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk) product `MCP` (`up-to-next-minor: 0.11.0`).
- 사양: MCP **2025-11-25**. 통신은 stdio 위 JSON-RPC.
- 호스트 환경: Swift 6.0+ / macOS 13+. 현재 toolchain은 Swift 6.3.1 / Xcode 26 / arm64-apple-macosx26.

## 통신 규약

- **stdout은 프로토콜 채널.** 진단 메시지를 stdout에 쓰면 클라이언트가 파싱 실패. 로그·디버그는 stderr 또는 파일.
- 에러 채널 매핑:
  - 인자 스키마 위반·알 수 없는 도구 → **Protocol Error**
  - 외부 프로세스 호출 실패·sandbox 거부·timeout → **Tool Result `isError: true`**
  - 사용자 Swift 코드의 컴파일 진단(에러·워닝 포함) → **Tool Result success** + content에 진단 (정적 분석 도구의 결과는 진단 자체가 산출물)

## 응답 크기 정책

도구 응답은 LLM 컨텍스트로 들어갑니다. 큰 산출물(SIL/AST/IR/모듈 trace 등)은 **임시 파일 경로 + 요약 통계**로 반환하고 본문에 포함하지 않습니다. 임시 파일은 호출당 격리 디렉토리(`$TMPDIR/swiftmcp-<call-id>/`).

## 진행 계획

전체 단계는 **`.claude/PLAN.md`**에 있습니다. 작업 전 PLAN을 읽고, 각 Stage 종료 시 갱신합니다.

## Knowledge Authority

`.claude/references/`의 문서는 학습 데이터보다 우선합니다. 목록: `.claude/references/_index.md`.

- 모르는 API → 참조 문서에서 먼저 검색
- 참조 문서와 학습 데이터 충돌 시 → 참조 문서 우선
- 참조 문서에 없는 경우 → 로컬 toolchain 출력(`swiftc -help-hidden`, `swiftc -frontend -help-hidden`, `swiftc -frontend -emit-supported-arguments`) → context7 또는 웹 검색 폴백

> swiftc는 **현재 toolchain의 자체 출력**이 1차 출처입니다. 외부 문서나 학습 데이터는 toolchain보다 뒤처질 수 있습니다.

## 작업 규칙

- Stage 종료는 검증 명령(빌드·테스트·실행)으로 확인합니다. "거의 다 됐다"는 종료가 아닙니다 (Global Rule #4).
- 도구는 PLAN의 해당 Stage에 정의된 범위만 추가합니다. "혹시 모를 옵션"을 미리 노출하지 않습니다 (Global Rule #2).
- 인접 코드의 형식·이름·구조를 임의로 바꾸지 않습니다. 작업 범위만 손댑니다 (Global Rule #3).
- 결정 사항을 변경할 때는 본 문서나 PLAN의 해당 절을 새로 쓴 형태로 교체합니다. 이전 결정의 흔적(부정·비교 문장)을 남기지 않습니다.
