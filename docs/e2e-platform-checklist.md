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

## 지도/로드뷰 점검
- [ ] 지도 렌더링 정상(허용 URL 설정 포함)
- [ ] 로드뷰 렌더링 정상
- [ ] GPS 이동 시 지도/로드뷰 동기화

## HTTPS/보안 점검
- [ ] 모바일에서 HTTPS 접속 가능
- [ ] 인증서 신뢰 체인 설정 후 Geolocation 정상
- [ ] HTTPS 페이지에서 WSS 연결 정상

## 로그 점검
- [ ] `can_<session>.csv` 생성 및 샘플 값 확인
- [ ] `gps_<session>.csv` 생성 및 타임스탬프 확인
- [ ] `gps_<session>.csv`의 `meta(source/bg_state/os/app_ver/device)` 컬럼 기록 확인
- [ ] `events_<session>.csv`에 MARK 기록 확인

## 결과 요약
- Pass/Fail:
- 주요 이슈:
- 재현 절차:
- 조치 담당/기한:
