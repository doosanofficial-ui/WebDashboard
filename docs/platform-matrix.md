# Platform Implementation Matrix & Checklist

## 목적
- 현재 WebDashboard 구조를 기준으로, 기능별 공통 구현 가능 범위와 플랫폼별 필수 커스터마이징 범위를 명확히 정의한다.
- 백그라운드 동작(연속 위치/GPS uplink)과 CarPlay/Android Auto 전환을 위한 단계별 체크리스트를 제공한다.

## 기능별 매트릭스

| 기능 | 공통(Web) 재사용 | iOS Safari/PWA 필수 커스터마이징 | Android Chrome/PWA 필수 커스터마이징 | 네이티브 전환 필요성 |
|---|---|---|---|---|
| CAN 실시간 수신(10Hz) | `FastAPI + WebSocket + JSON` 공통 | HTTPS 페이지에서는 `wss://` 강제, 인증서 신뢰 이슈 대응 | 백그라운드/절전 시 소켓 복구 튜닝 | 낮음 |
| 10Hz 렌더/게이지/그래프 | Canvas 렌더 루프 공통 | iOS viewport/safe-area 대응 | 주소창 축소/확장에 따른 높이 보정 | 낮음 |
| GPS foreground 표시 | Geolocation API 공통 | 권한 UX와 HTTPS 신뢰체인 중요, 업데이트 rate 비보장 | 권한 재요청/배터리 최적화 예외 안내 | 낮음 |
| GPS background 연속수집 | Web만으로 제약 큼 | Safari/PWA 백그라운드 위치 제한 강함 | 브라우저 백그라운드 제약 존재 | 높음(네이티브 권장) |
| MARK/이벤트 uplink | WS uplink 공통 | 앱 백그라운드 복귀 시 재전송 큐 필요 | 동일 | 중간 |
| PWA 설치/오프라인 캐시 | manifest/sw 공통 | 수동 설치 가이드(UI) 필수 | 설치 프롬프트(`beforeinstallprompt`) 활용 | 중간 |
| 지도/로드뷰 | 지도 SDK 공통 | API 허용 URL(HTTP/HTTPS/LAN IP) 엄격 관리 | 동일 | 낮음 |
| OBD BLE 직접 연결 | 공통 어려움 | iOS Safari WebBluetooth 미지원 | 일부 Android 브라우저 가능 | 높음(플랫폼별 분기) |
| CarPlay/Android Auto 화면 전환 | Web UI 일부 재사용 가능 | CarPlay entitlement/template 정책 준수 | Android Auto 카테고리/템플릿 준수 | 매우 높음 |

## 현재 상태 요약
- 완료: Web 기반 실시간 대시보드, GPS foreground 표시, WS 재연결, MARK uplink, PWA 기본 캐시, 지도/로드뷰 표시.
- 미완료: 신뢰 가능한 background telemetry(양 플랫폼), CarPlay/Android Auto 공식 투영 화면.

## 단계별 체크리스트

### A. Web 공통 레이어 안정화 (현재~단기)
- [x] WS 데이터 계약(v1) 고정 및 `seq/drop` 모니터링
- [x] GPS event-driven 수신 + 10Hz tick 보간/스무딩
- [x] stale/재연결 상태 표시
- [x] HTTPS 개발 인증서 가이드 및 iOS 신뢰 절차 문서화
- [x] 플랫폼별 E2E 점검표 자동화(iOS Safari, Android Chrome, 데스크톱)

### B. Background Telemetry 전환 (중기)
- [x] 모바일 런타임 결정(React Native + Native Bridge) 및 ADR 작성
- [x] Bare React Native 스캐폴딩 생성 및 foreground GPS uplink baseline 구현
- [x] iOS 우선 파일럿(always 권한 + significant-change 옵션 + Info.plist 자동 설정 스크립트)
- [ ] Background location 서비스 구현(iOS Significant-Change + Android FGS) — iOS: 구현 완료 / Android: FGS 스캐폴드 완료(서비스 구현은 진행 중) — 가이드: [`docs/android-fgs-bg-location.md`](android-fgs-bg-location.md) — 검증 절차: [`docs/reports/ios-bg-30min-template.md`](reports/ios-bg-30min-template.md)
- [ ] 앱 백그라운드 상태에서도 GPS uplink 지속(저주기 + 배터리 정책)
- [x] 네트워크 단절/복귀 시 store-and-forward 큐 적용(모바일 baseline)
- [ ] 배터리/발열 측정 기준 정의(예: 1시간 주행 기준 소모율)
- [x] 서버 수신 스키마 확장(`source`, `bg_state`, `os`, `app_ver`, `device`)

### C. CarPlay / Android Auto 전환 (중장기)
> 전환 전략 및 단계별 백로그: [`docs/adr/0002-carplay-android-auto-transition.md`](adr/0002-carplay-android-auto-transition.md)
- [ ] 차량 투영 플랫폼 요구사항 조사 및 승인(엔타이틀먼트/카테고리) 체크리스트
- [ ] 운전자 방해 최소화 HMI 규칙에 맞춘 화면 템플릿 설계
- [ ] 텔레메트리 핵심 카드(속도, yaw, 경고, 연결상태) 우선 UI 재구성
- [ ] Projection 연결 상태와 서버 WS 상태를 분리 모니터링
- [ ] 심사/배포 정책 대응(앱 심사 문구, 개인정보, 위치 권한 목적 고지)
- [ ] 장애 대응 플로우(Projection 실패 시 모바일 대시보드 폴백)

## 수용 기준(Phase Gate)
- Gate A (Web 안정화):
  - iOS/Android에서 10분 주행 시 재연결 포함 데이터 표시 유지
  - GPS no-fix/denied/unavailable 상태가 오탐 없이 구분 표시
- Gate B (Background):
  - 화면 OFF/백그라운드 30분 동안 GPS uplink 누락률 기준 충족 — 보고서 양식: [`docs/reports/ios-bg-30min-template.md`](reports/ios-bg-30min-template.md)
  - 앱 복귀 시 데이터 타임라인 불연속 구간 표시 가능
- Gate C (Projection):
  - CarPlay/Android Auto 양쪽에서 핵심 KPI 카드 렌더 및 경고 표시 확인
  - 투영 연결 단절 시 5초 내 모바일 화면 자동 폴백
