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

- [ ] **P1-2 설정파일(signals.json) 기반 신호 선택/스케일링**
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

- [ ] **P2-2 야간/주간 모드 토글**
  - 산출물: theme toggle UI, CSS variables 확장
  - 완료 기준:
    - 주행 중 한 번의 탭으로 모드 전환

- [x] **P2-3 간단 맵 표시(옵션)**
  - 산출물: heading + recent breadcrumb 혹은 경량 지도 레이어
  - 완료 기준:
    - 최근 궤적/방향 확인 가능
