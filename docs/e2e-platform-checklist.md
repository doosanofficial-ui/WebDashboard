# E2E Platform Validation Checklist

이 문서는 릴리스 전 플랫폼별 동작을 동일 기준으로 검증하기 위한 체크리스트다.

## 테스트 메타
- Build/Commit:
- Test date:
- Tester:
- Server mode: HTTP / HTTPS
- Network: local Wi-Fi / hotspot / tethering

## 환경 매트릭스
| Platform | Browser/App | OS Version | Device | Result |
|---|---|---|---|---|
| macOS | Chrome |  |  |  |
| iOS | Safari |  | iPhone/iPad |  |
| Android | Chrome |  | Phone/Tablet |  |
| iOS | Telemetry Mobile (RN) |  | iPhone/iPad |  |
| Android | Telemetry Mobile (RN) |  | Phone/Tablet |  |

## 공통 기능 점검
- [ ] `/api/ping` reachable
- [ ] WS connect/disconnect/reconnect(backoff) 동작
- [ ] CAN 10Hz 수신(60초 동안 seq 증가/드랍 수치 관측)
- [ ] UI stale 상태 전환/복구
- [ ] MARK 이벤트 uplink 및 CSV 기록

## GPS Foreground 점검
- [ ] 위치 권한 프롬프트 정상 표시
- [ ] GPS fix 후 lat/lon/speed/heading/accuracy 표시
- [ ] GPS stale/no-fix 상태 표기 정확
- [ ] 10Hz 렌더 루프에서 값 떨림이 과도하지 않음
- [ ] iOS 앱에서 always 권한 + background mode 설정 후 significant-change 수신 확인

## 지도/로드뷰 점검
- [ ] 지도 렌더링 정상(허용 URL 설정 포함)
- [ ] 로드뷰 렌더링 정상
- [ ] GPS 이동 시 지도/로드뷰 동기화

## HTTPS/보안 점검
- [ ] 모바일에서 HTTPS 접속 가능
- [ ] 인증서 신뢰 체인 설정 후 Geolocation 정상
- [ ] HTTPS 페이지에서 WSS 연결 정상

## 로그 점검
- [ ] `server/logs/can_<session>.csv` 생성 및 샘플 값 확인
- [ ] `server/logs/gps_<session>.csv` 생성 및 타임스탬프 확인
- [ ] `server/logs/gps_<session>.csv`의 `meta(source/bg_state/os/app_ver/device)` 컬럼 기록 확인
- [ ] `server/logs/events_<session>.csv`에 MARK 기록 확인
- [ ] WS 단절 후 재연결 시 queued GPS uplink가 순차 반영되는지 확인

## iOS 백그라운드 30분 시나리오 점검

> 전체 절차 및 보고서 양식: [`docs/reports/ios-bg-30min-template.md`](reports/ios-bg-30min-template.md)

### 준비
- [ ] iOS 기기에서 앱 설치 및 `always` 위치 권한 부여 확인
- [ ] `UIBackgroundModes: location` 활성화 확인 (`npm run ios:setup-bg` 실행 또는 Xcode Capabilities 확인)
- [ ] 서버가 LAN으로 바인딩됐는지 확인 (`HOST=0.0.0.0 python app.py`)
- [ ] 배터리 잔량 기록 (시작 전)

### 실행
- [ ] 앱 Connect 후 WS/GPS 정상 수신 확인 (최소 30초 foreground 유지)
- [ ] 화면 잠금(홈 버튼 또는 전원 버튼으로 화면 OFF)
- [ ] 30분 타이머 시작
- [ ] (선택) 15분 경과 시 서버 재시작 또는 네트워크 토글로 단절 시뮬레이션

### 로그 추출 및 측정
- [ ] 30분 후 앱 foreground 복귀 및 WS 상태 확인
- [ ] `server/logs/gps_<session>.csv` 추출 — 총 행 수, `bg_state` 컬럼, 타임스탬프 갭 확인
- [ ] 타임스탬프 갭 > 30초인 구간 목록 작성
- [ ] 큐 flush 완료 여부 확인 (단절 구간 이후 레코드 연속성)
- [ ] 배터리 잔량 기록 (종료 후)

### 핵심 지표 (보고서에 기재)
- [ ] **GPS 누락률** ≤ 20% (기준 충족 여부)
- [ ] **WS 재연결 성공률** 100%
- [ ] **큐 flush 완료** (Y/N)
- [ ] **GPS 신선도 지연** ≤ 300초

## 결과 요약
- Pass/Fail:
- 주요 이슈:
- 재현 절차:
- 조치 담당/기한:
