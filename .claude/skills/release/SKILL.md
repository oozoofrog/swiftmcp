---
name: release
description: 버전 태그 생성 및 GitHub Actions 릴리스 파이프라인 트리거. /release <version> 형태로 호출.
disable-model-invocation: true
---

# Release

swiftmcp의 새 버전을 릴리스합니다.

## 사용법

```
/release 0.2.0
```

## 절차

1. **사전 검증**
   - `swift build -c release` 성공 확인
   - `git status`로 uncommitted 변경 없는지 확인
   - 현재 브랜치가 `main`인지 확인

2. **태그 생성**
   - `git tag v{version}` 실행
   - 태그 메시지: `Release v{version}`

3. **푸시**
   - 사용자에게 `git push origin v{version}` 실행 여부 확인
   - 확인 시 태그 푸시 → GitHub Actions `release.yml` 자동 트리거

4. **확인**
   - `gh run list --workflow=release.yml --limit=1`로 CI 상태 확인
   - 릴리스 URL 출력

## 주의사항

- 인수가 없으면 `git tag --sort=-v:refname | head -5`로 최근 태그 표시 후 다음 버전 제안
- semver 형식만 허용 (x.y.z)
- 이미 존재하는 태그는 거부
