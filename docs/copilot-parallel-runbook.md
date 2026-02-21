# Copilot Parallel Runbook (iOS-first P3-3)

## 목적
- P3-3(백그라운드 위치 uplink) 작업을 Copilot Coding Agent에 병렬로 분할해 처리한다.
- 충돌을 줄이기 위해 트랙별 파일 경계를 명시하고, 병합 순서를 고정한다.

## 사전 조건
- GitHub CLI 인증 완료(`repo`, `workflow` scope)
- 저장소 관리자 권한 또는 issue/label 생성 권한
- 리포 루트 `AGENTS.md` 준수

## 병렬 트랙 생성
```bash
python3 scripts/copilot/assign_parallel_issues.py \
  --repo doosanofficial-ui/WebDashboard \
  --base-branch main
```

이 스크립트는 다음을 자동 처리한다.
- 병렬 라벨 생성/갱신 (`parallel-track`, `ios-first`, `p3-3`, ...)
- Copilot 할당 이슈 4개 생성
- 각 이슈에 `agent_assignment`(base branch + custom instructions) 설정

현재 생성된 트랙:
- Track-A: https://github.com/doosanofficial-ui/WebDashboard/issues/9
- Track-B: https://github.com/doosanofficial-ui/WebDashboard/issues/10
- Track-C: https://github.com/doosanofficial-ui/WebDashboard/issues/11
- Track-D: https://github.com/doosanofficial-ui/WebDashboard/issues/12

## 진행 모니터링
```bash
$HOME/.local/bin/gh issue list -R doosanofficial-ui/WebDashboard \
  --label parallel-track --state open
```

```bash
$HOME/.local/bin/gh pr list -R doosanofficial-ui/WebDashboard \
  --search "is:open label:parallel-track"
```

## 병합 순서 (권장)
1. Track-A (iOS native lifecycle)
2. Track-B (queue reliability)
3. Track-D (CI/smoke)
4. Track-C (validation docs)

## 충돌 최소화 규칙
- Track-A: `mobile/ios/**`, `gps-client.js`, `config.js` 중심
- Track-B: `store-forward-queue.js`, `App.js` queue 영역 중심
- Track-C: 문서 전용
- Track-D: CI/검증 스크립트 전용

PR 리뷰 시 확인:
- 대상 파일 경계 준수 여부
- unrelated 변경 포함 여부
- acceptance criteria 충족 여부

## 실패/재시도
- Copilot 할당 실패 시:
  - 동일 이슈를 수동으로 Copilot 재할당
  - 또는 이슈 본문/지침을 좁혀 재생성
- 장시간 무응답 시:
  - 트랙을 더 작은 단위 이슈로 분할
  - 우선순위 높은 트랙부터 수동 진행
