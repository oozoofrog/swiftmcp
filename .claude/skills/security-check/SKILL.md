---
name: security-check
description: swiftmcp 알려진 보안 이슈(#1 인수 주입, #2 압축 해제, #3 DispatchSemaphore, #4 SIGINT) 점검
---

# Security Check

swiftmcp의 4개 알려진 보안 이슈 상태를 점검합니다.

## 점검 대상

### #1 SourceResolver buildCommand 인수 주입
- `Sources/swiftmcp/Resolver/SourceResolver.swift`에서 `Process` 호출 시 사용자 입력이 안전하게 처리되는지 확인
- `arguments` 배열 사용 여부, shell string interpolation 부재 확인

### #2 CacheManager 압축 해제 보안
- `Sources/swiftmcp/Cache/CacheManager.swift`에서 tar.gz 해제 시 경로 순회 방지 확인
- 해제 경로가 캐시 디렉토리 내부로 제한되는지 확인

### #3 init 템플릿 DispatchSemaphore 안티패턴
- `Sources/swiftmcp/Templates/PackageTemplate.swift`의 `mcpProtocolSwift()` 함수에서 `DispatchSemaphore` 사용 여부
- Swift 6.2 strict concurrency와 호환되는 async/await 패턴으로 전환되었는지 확인

### #4 InteractiveMenu SIGINT 터미널 복원
- `Sources/swiftmcp/TUI/InteractiveMenu.swift`에서 SIGINT 수신 시 터미널 설정이 복원되는지 확인
- `tcsetattr`로 원래 설정 복원 경로 존재 여부

## 출력

각 이슈에 대해:
- **상태**: 해결됨 ✅ / 미해결 ⚠️ / 악화됨 🚨
- **근거**: 관련 코드 위치와 현재 구현 상태
- **권장 조치**: 미해결 시 구체적 수정 방향
