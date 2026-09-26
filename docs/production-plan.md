# 사내 테스트 엔지니어용 배포 계획

기준일: 2026-09-19. 근거: [현재 진단](reports/commercial-readiness-2026-09-19.md).
사용자 확정: Windows 계측 서버 + iPhone/iPad, 우선 iPhone 17 / iOS 27
(2026-09-23 사용자 업데이트). 정확한 OS 빌드 번호는 다음 실기기 연결에서 확인한다.
기존 PRD와 추가 요구인 백그라운드·CarPlay를 전체 목표로 유지한다.
2026-09-23 추가 목표: 보유 NANICAR ELM327-BT4N OBD-II 스캐너를
현대 싼타페 MX5 HEV(연식 미확인)에 연동한다. iPhone BLE 직접 연결 우선,
Windows 브리지 대안이며 실물 호환은 아직 미검증이다.
단계 하나의 통과를 전체 목표 달성으로 처리하지 않는다.

최신 구현/검증 증거: [네이티브 체크포인트](reports/native-milestone-2026-09-23.md),
[서버 장애 복구](reports/server-fault-recovery-2026-09-23.md),
[OBD 후보 실제 평가](reports/obd-candidate-qualification-2026-09-23.md).
시뮬레이터/ARM64 빌드와 Core 검사는 통과했지만 실기기 및 전체 출시 판정은 미완료다.
기존 Xcode 26.3 / iOS 26.2 시뮬레이터 결과는 iOS 27 호환성 증거가 아니다.
현재 Mac은 macOS 26.6.2로 Xcode 27의 호스트 요구사항(26.6 이상)을 충족한다.
다음 모바일 검증은 Xcode 27 / iOS 27 SDK 준비, 기기 연결·서명 확인,
동일 소스 재빌드·설치, 30분 잠금 시험 순서로 진행한다.
근거: [Apple SDK 및 시스템 요구사항](https://developer.apple.com/xcode/system-requirements/).

## 1. P0 빌드와 데이터 무결성

- [ ] **C01 소스 복원**: Git/CI 다운로드, 기존 수정 보존, 실제 branch/remote 대조.
  완료: Git diff/이력을 읽을 수 있고 수정 커밋 추적 가능.
- [x] **C02 GPS 무결성 검사**: null/0/범위/콜백/브리지 누락 회귀 검사.
  증거: scripts/tests/gps-data-integrity.test.mjs 19 PASS. 소스 검사만 완료이며 실기기/배포 완료가 아님.
- [ ] **C03 모바일 빌드**: iOS는 Swift/Core Location 네이티브 앱으로 전환한다.
  기존 구현 교체에 대한 사용자 승인(2026-09-19)에 따른 결정: [ADR-0003](adr/0003-native-ios-reliable-ingest.md).
  완료: 깨끗한 환경의 Debug/Release 빌드, iPhone 설치 및 실제 네이티브 위치 수집.
- [ ] **C04 계측 시각·품질**: 측정/수신 시각 분리, 모름·정지·stale 구별.
  완료: 오래된 위치/재전송이 fresh로 둔갑하지 않는 native/web/CSV 회귀 검사.
- [ ] **C05 서버 입력·기록**: 버전/타입/범위/크기 검증, 느린 구독자 분리, 세션 충돌/디스크 오류 처리.
  진행: 느린 뷰어 격리/CSV 충돌 방지 후, lifespan 재시작·원본 누락 방지·실제 수집/기록 장애 health와
  변환 전 NaN 거부 및 시작 직후 취소를 서버 35개 테스트/실제 loopback으로 검증했다.
  legacy uplink의 크기/JSON/버전/필드 검증과 웹 오류 표시는 추가 구현했다.
  서버 43개, GPS/map/WS/UI 26개, 서비스 워커 8개 테스트 통과. 실제 브라우저에서
  저장 실패 경고, 1009 원인 표시·재연결, 모바일 크기의 표시 영역을 확인했다.
  2026-09-24: [CSV 프로세스 격리](adr/0005-isolated-csv-recording.md), 제한 큐,
  저장 지연/실패 표시, 종료·취소·부모 연결 종료 회수를 구현했다. 로컬 서버 63개,
  웹 28개, 서비스 워커 8개, 네이티브 Core 26개 테스트 및 iOS 26.2 SDK 빌드 통과.
  v2 SQLite 고착 종료 정책·설정 검증·실제 Windows 저장장치/콘솔 검증은 남아 있다.
  완료: 손상 입력 후에도 정상 10Hz 지속, 재시작 전후 기록 보존.

## 2. P0 백그라운드와 전송 신뢰성

- [ ] **C06 영속 수집·ACK**: 네이티브 수집과 중단 정책, event ID, 기록 ACK, 영속 큐, 중복 제거, overflow 경고.
  완료: ACK 전 큐 삭제 금지, 단절 중 수집값이 복귀 후 정확히 한 번 논리적으로 기록됨.
- [ ] **C07 iPhone 30분 실측**: 동일 빌드의 전경/30분 잠금/망 단절/복귀/MARK.
  완료: 원본·ACK 대조, background 구간/권한/모드/배터리와 판정 지표 기록.
- [ ] **C08 분석기**: GPS 고정 Hz 가정 대신 생성된 원본 sequence와 ACK로 유실 측정.
  완료: significant-change 정지 구간의 이벤트 미발생/전송 실패 구별,
  무기록·부분 시험·과거 로그가 PASS로 처리되지 않는 검사.

기존 20% 이하 누락률/재연결 100%/큐 flush/신선도 300초 이하는 파일럿 기준이다.
사내 출시에는 재전송 후 미설명 유실 0건 및 수신 중복 제거를 추가 조건으로 둔다.
원본 수집 자체가 없었던 구간은 별도 표시한다.

## 3. P0/P1 사내 설치와 운영

- [ ] **C09 Windows 패키지**: Python 3.11+ 런타임, 원클릭 시작/종료, 설정·로그 분리, 업그레이드·롤백.
  진행: `server/start.ps1`/`start.cmd`가 loopback 기본 바인딩, venv 생성, requirements hash 기반 갱신,
  명시적 LAN 바인딩을 제공한다. Windows clean-machine/재부팅/방화벽/롤백 실측 전에는 완료 처리하지 않는다.
  완료: 깨끗한 Windows에서 설치 후 1분 내 더미 접속, 재부팅/업데이트 후 설정·로그 보존.
- [ ] **C10 연결 보안**: 페어링, TLS/Origin, 키 비공개 보관, 위치 기록 보존·삭제.
  진행: 서버 기본 CORS wildcard를 제거하고 `ALLOWED_ORIGINS` 명시 목록만 허용하도록 고정했다.
  기본 정적 dashboard는 same-origin으로 동작하며, 실제 LAN TLS/기기 차단/보존·삭제 정책은 별도 gate다.
  완료: 비허용 기기 차단과 허용 기기의 정상 동작.
- [ ] **C11 의존성**: 취약점 영향/수정/예외 사유, SBOM/라이선스 정리.
  완료: 배포 경로에 미해결 중대 취약점이 없고 호환 업그레이드 빌드·회귀 통과.
- [ ] **C12 UI/PWA/지도**: 더미/실차 모드 명시, 가독성/분할 조절, 정적 캐시 업데이트, 네이버 동기화.
  완료: 데스크톱/iPhone/iPad UI 및 오프라인/업데이트 실측. 맵 실패가 텔레메트리를 중단시키지 않음.
- [ ] **C13 실차 adapter**: CANoe 브리지 우선 후보, CANape/MATLAB SDK·라이선스 확인.
  완료: VN1640A 신호 7ch의 단위·스케일·시각을 원본 도구와 대조.
  GPS API에 CAN 데이터를 넣도록 한 기존 문서 예시는 교정했으며 실제 CAN push 계약/수신기는 미구현.
- [ ] **C14 내구성**: 1시간 CAN 10Hz + GPS, P95 표시 지연 250ms 목표, 메모리/디스크/배터리·발열 측정.
  완료: 무응답·증가형 메모리 누수·미설명 유실 없음.

## 4. 필수 후속 플랫폼과 배포 승인

- [ ] **C15 CarPlay**: 실제 용도에 맞는 카테고리/entitlement 확인, 지원 템플릿/복귀 구현.
  완료: 시뮬레이터와 지원 기기/차량 검증 및 필요한 권한 증거.
  불허 시 별도 결정 필요. 웹 UI나 위젯만으로 전체 CarPlay 요구 완료를 대신하지 않는다.
- [ ] **C16 Android**: FGS/권한/네이티브 저장, 에뮬레이터 후 실기기 검증.
  완료: 같은 30분/단절 기준 통과. 기기 부재는 미검증으로 유지.
- [ ] **C17 사내 iOS 배포**: USB 개발 빌드 검증 후 실제 조직 계정·관리 환경에 따라 TestFlight/Ad Hoc/관리형 경로 확정.
  완료: 지정된 사내 기기에 설치/업데이트/회수 가능. 비용·계정·서명/MFA는 대상 확정과 사용자 인증 필요.
- [ ] **C18 릴리스 결합**: 기능 수정 commit/version/manifest/패키지 SHA-256/runtime/설치 UI/시험 보고서 일치.
  완료: 모든 필수 항목의 최신 증거 확인 후 전체 상용화 판정.

## 5. 추가 필수 목표: 보유 OBD 스캐너 (2026-09-23)

설계: [ADR-0004](adr/0004-obd-bt4n-integration.md).
장비별 실행표: [BT4N / MX5 HEV](reports/obd-bt4n-compatibility.md).
기존 C13 Vector 경로를 대체하지 않으며 C18 출시 판정에도 아래 항목을 포함한다.

- [ ] **C19 P0 실물 프로파일 확인**: BLE GATT/serial 후보, 펌웨어, 12V 조건, 차종·연식·PID capability 기록.
  완료: 선택한 BT4N의 실제 서비스/특성/응답과 MX5 HEV의 지원 PID 증거 확보. 포장만으로 PASS 금지.
- [ ] **C20 P0 iOS OBD 수집**: Core Bluetooth transport, 명령 allowlist, prompt parser, 단일 질의·타임아웃·재연결.
  진행: `TelemetryCore/ELM327.swift` 순수 파서/4개 PID 명령, allowlisted raw-monitor session,
  synthetic XCTest, versioned `AdapterProfile`/signal catalog와 simulator
  `MockCANTransport -> decoder -> recorder -> UI` vertical slice를 구현했다.
  BLE 연결/실차 샘플/UI/업링크는 아직 연결하지 않았으며 이 단계만으로 완료 처리하지 않음.
  완료: iOS 27 실기기에서 지원 PID 읽기, 권한 거부/분할 응답/단절/Stop 회귀 검사 통과.
- [ ] **C21 P1 Windows OBD 브리지**: 확인된 BLE 또는 serial transport와 비차단 sample cache.
  완료: Windows 실물 연결, 느린 OBD 응답에도 CAN 10Hz 지속, 웹/iPad 표시 확인.
- [ ] **C22 P0 데이터 계약·영속 기록·UI**: source/PID/unit/quality/observed_t, 버전 있는 OBD uplink/ACK/CSV, 전용 게이지.
  완료: 재전송 무손실·중복 제거, 실제 샘플률과 10Hz 렌더 구별, OBD 속도를 휠 4ch로 위장하지 않음.
- [ ] **C23 P0 OBD 백그라운드 실측**: 잠금 30분, Bluetooth/네트워크/전원 단절과 복귀를 각각 검증.
  완료: 원본 이벤트와 ACK 대조, GPS/OBD/업링크 별도 판정. 지속 polling 불가 시 Windows 수집 대안 실측.
- [ ] **C24 P1 MX5 HEV 호환 승인**: 기준 진단기와 값/단위 대조, 엔진 정지 RPM 0·미지원·no-data 구별.
  완료: 같은 앱/서버 빌드의 차종·연식·장비 프로파일과 실제 PID 목록 공개. 제조사 전용 HEV 값은 추측 금지.
- [ ] **C25 P0 오픈소스 채택 검증**: 스타 수와 별도로 실제 사용 보고·미해결 결함·라이선스·대상 플랫폼 평가.
  조사: [8개 후보 및 Pelican/OBDb 근거](reports/obd-oss-research-2026-09-23.md).
  완료: 고정 commit 후보의 빌드/재연결/실물 재현과 재사용 조건 확인. 충분한 독립 성공 사례가 없으면
  부족함을 명시하고 승인 완료로 처리하지 않음. 공개 저장소/별점/댓글 수를 실차 성공 건수로 계산하지 않음.
  iOS는 LTSupportAutomotive/SwiftOBD2 비교 평가를 우선한다. 자체 전체 스캐너 스택 확장보다 이 평가가 선행한다.
  실제 [고정 커밋 평가](reports/obd-candidate-qualification-2026-09-23.md): 두 SDK 모두 빌드는 되지만
  timeout/PID 분리 acceptance에서 실패하여 수정 없는 런타임 채택은 보류한다.

## 검증 운영

- 수정 전 실패 재현, 실제 코드 경로를 사용하는 수정 후 검증.
- 파일 존재 검사·문서 검사·JS 단위 테스트는 실기기 시험을 대체하지 않는다.
- Git 복원 전 이력과의 통합을 추측하거나 원격으로 업로드하지 않는다.
- 단계마다 실제 결과로 이 계획과 진단 보고서를 갱신한다.
