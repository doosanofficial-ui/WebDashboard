# MVP Backlog (Epic/Story)

## P0
- [x] **P0-1 Server WS 송출(더미 CAN 10Hz) + 정적 호스팅 + iPad 표시**
  - 산출물: `server/app.py`, `server/can_source/dummy.py`, `client/index.html`
  - 완료 기준:
    - 서버 실행 후 `GET /api/ping` 정상 응답
    - `ws://<host>:8080/ws`로 10Hz 프레임 수신
    - iPad Safari에서 게이지 값이 갱신됨

- [x] **P0-2 iPad GPS watchPosition + 권한 UX + 10Hz 렌더 루프 + 보간/스무딩**
  - 산출물: `client/gps.js`, `client/app.js`, GPS 카드 UI
  - 완료 기준:
    - Start GPS 버튼으로 권한 프롬프트 발생
    - GPS 수신 주기가 느려도 10Hz UI tick에서 값이 연속 표시
    - stale 상태 표시 동작

- [x] **P0-3 게이지 + 60초 스크롤 그래프 + 연결상태/드랍 표시**
  - 산출물: `client/charts.js`, `client/ui.js`, `client/styles.css`
  - 완료 기준:
    - 6개 게이지 렌더
    - 2개 그래프가 최근 60초 window 유지
    - seq/drop/frame age/RTT 표시

- [x] **P0-4 재연결(backoff) + stale 표시**
  - 산출물: `client/ws.js`, `client/ui.js`
  - 완료 기준:
    - WS 끊김 시 exponential backoff 재연결
    - 데이터 끊기면 stale 상태로 전환

## P1
- [x] **P1-1 GPS 업링크 + 서버 CSV 로그 + MARK 이벤트 기록**
  - 산출물: `server/gps_sink.py`, `server/logger.py`, `client/app.js`
  - 완료 기준:
    - GPS 수신 시 `gps_<session>.csv` 기록
    - MARK 클릭 시 `events_<session>.csv` 기록

- [x] **P1-2 설정파일(signals.json) 기반 신호 선택/스케일링**
  - 산출물: `server/signals.json`, signal mapper 모듈
  - 완료 기준:
    - enabled signal만 송출
    - 단위/스케일 적용 가능

## P2
- [x] **P2-1 PWA 설치(캐싱)**
  - 산출물: `client/manifest.json`, `client/sw.js`
  - 완료 기준:
    - 홈 화면 설치 가능
    - 정적 리소스 캐싱

- [x] **P2-2 야간/주간 모드 토글**
  - 산출물: theme toggle UI, CSS variables 확장
  - 완료 기준:
    - 주행 중 한 번의 탭으로 모드 전환

- [x] **P2-3 간단 맵 표시(옵션)**
  - 산출물: heading + recent breadcrumb 혹은 경량 지도 레이어
  - 완료 기준:
    - 최근 궤적/방향 확인 가능

## P3 (Post-MVP)
- [x] **P3-1 플랫폼 매트릭스/체크리스트 운영 문서화**
  - 산출물: `docs/platform-matrix.md`, `docs/e2e-platform-checklist.md`, `scripts/validate_platform_docs.py`
  - 완료 기준:
    - iOS Safari / Android Chrome / Desktop 검증 항목과 결과가 문서로 관리됨
    - 릴리스 전 점검 체크리스트로 사용 가능

- [x] **P3-2 Background Telemetry 아키텍처 결정(ADR)**
  - 산출물: 런타임 선정 ADR(`docs/adr/` 예정), 기술 비교표
  - 완료 기준:
    - React Native/Flutter/Native 대안 비교(권한/배터리/유지보수/빌드체인)
    - 팀 합의된 단일 경로와 제외 사유 기록

- [ ] **P3-3 iOS/Android 백그라운드 위치 uplink 구현**
  - 산출물: 모바일 앱 모듈(신규), 서버 수신 스키마 확장
  - 진행 현황:
    - [x] 서버 GPS 수신 스키마에 `meta(source/bg_state/os/app_ver/device)` 반영
    - [x] Bare React Native 모바일 스캐폴딩(`mobile/`) + foreground GPS uplink/WS/MARK 구현
    - [x] iOS 우선 파일럿: always 권한 요청 + significant-change 옵션 + Info.plist 자동 설정 스크립트
    - [x] WS 단절 구간 GPS store-and-forward 큐 baseline 구현
  - 완료 기준:
    - 화면 OFF/백그라운드 30분 동안 GPS uplink가 기준 누락률 이하
    - 네트워크 단절 후 복귀 시 store-and-forward 재전송 동작
    - `gps_<session>.csv`에 foreground/background 상태 구분 기록
  - 즉시 실행 체크리스트:
    - [x] 오늘 실행 순서/명령/완료기준: `docs/reports/p3-3-next-actions-2026-02-21.md`
    - [x] Android 네이티브 소스 스캐폴드 2개(`LocationForegroundService`, `RNAndroidLocationBridge`)
    - [ ] 생성된 `android/` 프로젝트 반영 + ReactPackage 등록 + 30분 실측

- [ ] **P3-4 배터리/발열 계측 및 보호 로직**
  - 산출물: 샘플링 정책(동적 주기), 운영 가이드
  - 완료 기준:
    - 1시간 주행 시 배터리 소모/발열 리포트 확보
    - 저전력 모드 전환 기준과 경고 UI 정의

## P4 (Projection)
- [ ] **P4-1 CarPlay/Android Auto 정책/자격 요건 체크**
  - 산출물: 요구사항 매트릭스(엔타이틀먼트/카테고리/심사 조건)
  - 완료 기준:
    - iOS/Android 투영 진입 요건을 문서화하고 블로커 식별
    - 구현 가능 범위와 불가 범위를 팀 합의

- [ ] **P4-2 투영 전용 UI 템플릿 설계 및 PoC**
  - 산출물: 투영 UI 와이어/프로토타입, 데이터 바인딩 규격
  - 완료 기준:
    - 핵심 텔레메트리 카드 렌더링 검증(속도/yaw/경고/연결상태)
    - 운전 중 가독성 및 조작 최소화 기준 충족

- [ ] **P4-3 모바일 대시보드 <-> 투영 화면 폴백**
  - 산출물: 상태머신 설계, 연결 단절 복구 로직
  - 완료 기준:
    - Projection 끊김 시 5초 내 모바일 화면 자동 복귀
    - 복귀 시 데이터 연속성(시각화/로그) 유지
