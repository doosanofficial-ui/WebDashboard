# PRD: Wireless Telemetry Dashboard MVP

## 1. Product / Problem
- Windows 노트북에 연결된 CAN 계측 데이터를 iPad Safari에서 저지연(목표 250ms 이내)로 모니터링한다.
- iPad GPS(위치/속도/heading/accuracy)를 함께 표시한다.
- 주행 중 사용 가능한 CarPlay-like UI(큰 숫자, 단순 레이아웃, 연결품질/경고 표시)를 제공한다.

## 2. Goals / Non-goals
### Goals (MVP)
- CAN 데이터 10Hz 수신/표시
- 렌더는 부드럽게(목표 20fps 이상)
- GPS event-driven 수신 + 10Hz tick 기반 보간/스무딩 표시
- 핫스팟 환경에서 재연결(backoff) 및 stale 표시
- 세션별 CSV 로그(CAN/GPS/MARK)

### Non-goals (MVP)
- CarPlay 공식 화면 탑재
- ECU 제어/UDS 보안/차량 제어
- 다중 iPad 동시 구독 최적화

### Post-MVP Goals (Phase 2+)
- iOS/Android에서 백그라운드 위치 업링크를 안정적으로 지속할 수 있는 모바일 앱 경로 확보
- CarPlay/Android Auto 투영 화면으로 핵심 텔레메트리 카드(속도, yaw, 경고, 연결상태) 제공
- 모바일 foreground 대시보드와 투영 화면 간 상태 동기화 및 자동 폴백 제공

## 3. Constraints / Rationale
- `watchPosition()` 업데이트는 주기 보장 없음. 브라우저/OS rate limit/significant-change 정책 영향을 받음.
- GPS는 이벤트 기반 저장 후 10Hz 렌더 루프에서 보간/EMA로 화면 표시.
- iOS Safari WebBluetooth 제약으로 OBD BLE 직접연결 대신 노트북 서버<->iPad Wi-Fi(WS/HTTP) 사용.
- Geolocation 권한 이슈 대비 HTTPS 개발 인증서 옵션 제공.

## 4. Functional Requirements
### Server (Windows)
- 정적 호스팅: `/` -> client
- `GET /api/ping`
- `WS /ws`: CAN 10Hz broadcast + client uplink(GPS/MARK) 수신
- CSV 로그: `can_<session>.csv`, `gps_<session>.csv`, `events_<session>.csv`
- CAN source 인터페이스 분리(`can_source/base.py`)

### Client (iPad Safari/PWA)
- 연결 패널: 서버 URL, Connect/Disconnect
- 상태: connected/disconnected, frame age, seq, drop, RTT
- 게이지: ws 4ch + yaw + ay
- 그래프: 2개 canvas, 60초 스크롤, MARK 수직 마커
- GPS: Start 버튼, lat/lon/speed/heading/accuracy 표시, stale 표시
- 재연결: exponential backoff

## 5. Non-functional Requirements
- 10분 주행에서 자동 재연결 동작
- 드랍율/연결상태 가시화
- iPadOS Safari/Windows Chrome/Edge 호환
- Background phase에서는 화면 OFF/백그라운드 30분 기준 uplink 누락률 목표를 별도 정의
- Projection phase에서는 운전자 방해 최소화(HMI)와 플랫폼 심사 요구사항 준수

## 6. Data Contract (v1)
### Server -> Client (10Hz)
```json
{
  "v": 1,
  "t": 1730000000.123,
  "sig": {
    "ws_fl": 41.2,
    "ws_fr": 40.9,
    "ws_rl": 40.3,
    "ws_rr": 40.1,
    "yaw": 1.2,
    "ax": 0.4,
    "ay": -0.3
  },
  "status": { "seq": 1234, "drop": 2 }
}
```

### Client -> Server GPS (1~5Hz)
```json
{
  "v": 1,
  "t": 1730000001.456,
  "gps": {
    "lat": 37.123,
    "lon": 127.123,
    "spd": 8.2,
    "hdg": 92.4,
    "acc": 7.1,
    "alt": 35.5
  },
  "meta": {
    "source": "web|mobile",
    "bg_state": "foreground|background",
    "os": "iOS|Android|...",
    "app_ver": "string",
    "device": "string"
  }
}
```

### MARK Event
```json
{ "v": 1, "t": 1730000002.789, "type": "MARK", "note": "" }
```

## 7. Text Architecture
```text
[Vector/PEAK/CANoe/CANape/MATLAB/ATI]
           |
           v
   [server can_source adapter] --(v1 JSON @10Hz)--> [FastAPI WS /ws]
           |                                          |
           +--------> [CSV logger]                    +--> [iPad Safari client]
                                                           |- 10Hz UI tick (gauges)
                                                           |- Canvas scrolling charts (60s)
                                                           |- GPS watchPosition events
                                                           |- GPS interpolation + EMA
                                                           |- MARK uplink
```

## 8. Roadmap (MVP -> Projection)
### Phase A: Web MVP (완료)
- FastAPI + WS 10Hz 송출
- iPad/iPhone Safari 대시보드
- GPS foreground, MARK, CSV 로깅

### Phase B: Background Telemetry
- 모바일 런타임(React Native + Native Bridge) 결정 및 ADR 완료
- Bare React Native 스캐폴딩(`mobile/`) + foreground GPS uplink 구현
- iOS/Android 백그라운드 위치 수집 서비스 구현
- 단절 구간 store-and-forward 큐와 서버 스키마 확장

### Phase C: CarPlay / Android Auto
- 플랫폼 정책/엔타이틀먼트 확인
- 운전 중 사용 가능한 투영 UI 템플릿 설계
- 투영 실패 시 모바일 대시보드 폴백 자동화
