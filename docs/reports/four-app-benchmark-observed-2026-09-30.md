# 4개 iPhone 차량 앱 실측 벤치마크

실행일: 2026-09-30. 제품 코드 기준: ce5e3d0. iPhone 17 실기기, XCTest 직접 실행.

## 판정

네 앱을 직접 활성화하고 화면·접근성 트리·조작 기록을 확보했다. **전체 기능 검증 완료는 아니다.**
화면 진입, 데모 값 표시, 실제 차량 수집은 별도 증거다. 로그인/유료 기능/전용 하드웨어/실차 전용
기능과 미방문 하위 메뉴는 아래에 남겼다. XCTest 성공도 해당 navigation script 종료만 의미한다.

설치: Pelican 5.0.3(855), Car Scanner 2.1.46, ABRP 7.1.7(설치 5980, 설정 UI 6006),
OBDeleven 2.12.0(1790149781). ABRP 설치/화면 build 차이는 관찰 사실이며 원인은 미확인이다.

첫 인증 실행은 XCTest 암호 입력 대기로 timeout. 인증 후 entry-authenticated 실행은 새 테스트
파일의 프로젝트 등록 누락으로 기능 증거가 없었다. XcodeGen 갱신 후 entry-inventory부터 실제
앱 순회 및 캡처를 확인했다. details 실행의 Car Scanner 상단 버튼 탐색 실패를 보존했다.
후속 실행에서는 fullscreen gauge를 탭해 버튼을 다시 노출한 후 센서 목록으로 이동했다.
조건문으로 건너뛴 메뉴는 실행 성공으로 계산하지 않았다.

원본 결과: `/tmp/vehicle-benchmark-20260930/` 아래 entry-inventory, menus, deep, branches,
more, data, records, final, config의 log/xcresult. 개인 계정/VIN/위치 포함 원본은 Git에 넣지 않았다.
공유 가능한 화면은 [증거 목록](evidence/four-apps-20260930/manifest.json)에 SHA256, 시각, test ID로 연결한다.

## 직접 관찰한 기능과 도입 판단

| ID | 앱 / 직접 이동한 경로 | 확인한 결과 | 도입 판단 |
| --- | --- | --- | --- |
| PEL-01 | Garage | 차량 추가/OBD 연결 두 주 버튼 | 초기 진입 단순화 |
| PEL-02 | Add vehicle/account | Offline vehicle, Tesla/Volvo 계정, Simulated vehicles | 오프라인 차량 우선; 계정 연동 제외 |
| PEL-03 | Offline vehicle | VIN 입력/스캔/붙여넣기 등록 폼 | 수동 모델 등록도 제공, VIN 필수화 금지 |
| PEL-04 | Simulated vehicles | 복수 차종/오프라인/정비중 시나리오 | 원천과 실행 모드 분리된 fixture |
| PEL-05 | PanameraEHybrid demo | 연료·배터리·속도·효율·마지막 갱신시각 요약 | HEV 복수 에너지 계통 요약; 실차값 아님 |
| PEL-06 | Logbook | Documents/Journeys/Records/Scan sessions, CarPlay 빠른 목적지 | 계측 세션 중심 기록 허브 |
| PEL-07 | Scan sessions | 명령/응답 자동 기록 안내, 세션 없음 | 요청/응답 audit log; export 실행은 미검증 |
| PEL-08 | Map | Get started 온보딩 | 지도는 선택 기능 |
| PEL-09 | Settings | Profiles/Account/Vehicles/회원권/Map 등 | 차량·표시·저장 설정 분리 |
| CSC-01 | Home | 13개 기능 타일, ELM/ECU 연결 상태 분리 | transport 연결과 ECU 응답 구분 |
| CSC-02 | Demo | 모든 센서 / 마지막 차량 선택 | 차량별 데모, 합성 표시 필수 |
| CSC-03 | 마지막 차량 demo | Random engine ECU, 합성 VIN, 연결 표시 | 실제 연결처럼 오인하지 않게 명시 배지 |
| CSC-04 | Dashboard | 페이지 1/3, HUD, 숫자/아날로그 계기, 변화하는 합성값 | 동일 신호 다중 위젯/페이지 |
| CSC-05 | All sensors | 계산값·연료·에너지·단위 목록 | 실측과 계산값 분류 |
| CSC-06 | Live data | 개별/통합 차트 선택창 | 공통 시간축 / 별도 Y축 선택 |
| CSC-07 | Data recording | 기록/위치/반올림 설정, 가져오기, 기존 파일 | 원본 보존과 표시 반올림 분리 |
| CSC-08 | Settings | BLE (4.0): OBDII, Santa Fe MX5 HEV(2024–현재) | 사용자 장치/차량 식별 단서 |
| CSC-09 | Sensors | 사용자 정의/기본 OBD/활성·비활성/차량지원/우선순위/역할 | 선택·지원·주기 정책을 별도 모델화 |
| CSC-10 | Settings 기타 메뉴 | 단위/대시보드/차량옵션/연비/ABRP/백업/터미널/코딩 | 메뉴 존재 관찰, 각각의 동작은 미검증 |
| ABR-01 | Entry | 지도 + 하단 경로 패널, 차량추가, 저장경로 | 지도와 계측 요약 동시 표시 패턴 |
| ABR-02 | Settings | 차량/충전/경로/표시/개인정보/이력 | 설정 범주 명확화 |
| ABR-03 | Vehicle | 제조사 검색·모델수·차량 선택 목록 | 지원 범위 안내; HEV 지원 단정 금지 |
| ABR-04 | Charging | 충전카드/네트워크/제외/최대충전/시설/도착 SOC | 지역 서버 의존 기능은 보류 |
| ABR-05 | Routing | 정차수, 통행료/국경/고속도로/페리, 교통·속도·날씨 | 로컬 분석에 환경 조건 메타데이터만 차용 |
| ABR-06 | Privacy & Data | live data sharing, activity 저장, history/delete | 공유와 로컬 저장 구분; 삭제 실행 안 함 |
| OBD-01 | Home (기존 demo) | Golf GTE, 연결상태, 시스템 아이콘, Trip tracker/정비 | 차량 중심 홈 |
| OBD-02 | Vehicle | Apps/Control units/검사/정비/주행거리/배출/배터리 | ECU 중심 계측 진입 |
| OBD-03 | Control units | 상태 필터·검색, ECU ID/명칭/Faulty 배지 | ECU capability catalogue |
| OBD-04 | Engine | Faults/Live data/식별/코딩/Adaptations/Output tests | 읽기 전용 항목만 도입 |
| OBD-05 | Advanced live data | 설명 후 Continue → Vehicle not connected | 데모에서도 장비 필요, 값 확인 BLOCKED |
| OBD-06 | Faults | demo 고장 1건 및 Slide to clear | 고장 읽기만 후보; clear 실행 안 함 |
| OBD-07 | More | 장치/설정/도움말/언어/국가/지원차량/데모 | 계정 화면은 개인정보 제외 |

Car Scanner의 저장된 이름 **OBDII**는 후속 BT4N 식별 시 참고할 수 있다. 저장 설정만으로
현재 광고 중인지 또는 GATT UUID가 무엇인지 확인할 수 없다. 이전 '이름 일치 0개' 결과는
BT4N이 광고되지 않는다는 확정 증거가 아니며 이름 없는 주변기기의 정체도 미확인이다.

## 공통 패턴과 차별점

| 영역 | 공통 개념 | 앱별 차이 | 우리 앱 적용 |
| --- | --- | --- | --- |
| 차량 | 대상 차량 컨텍스트 | Pelican 차고, OBDeleven 차량/ECU, Car Scanner 연결 프로필, ABRP EV 모델 | VehicleProfile 아래 ECU/신호/레이아웃 연결 |
| 연결 | 데이터 사용 가능 여부 | Car Scanner ELM/ECU 이중 상태, OBDeleven disconnected gate | BLE/ELM/ECU/신호 품질 4단계 |
| 표시 | 값과 단위 | Car Scanner 자유 계기, Pelican 요약, ABRP 경로, OBDeleven 시스템 분류 | 편집 Dashboard + ECU별 목록 |
| 기록 | 이전 데이터 접근 | Pelican 원본 scan, Car Scanner 센서 녹화, ABRP trip/charge, OBDeleven 차량 이력 | 원본 응답+물리값+GPS 단일 세션 |
| 미지원 | 선행 조건 안내 | 차량없음/장비없음/계정/구독 | 원인과 다음 조작 표시, 0으로 대체 금지 |
| 데모 | 실물 없이 탐색 | Pelican 차종/상태 시뮬레이션, Car Scanner 차량별 합성, OBDeleven 일부 제한 | LIVE/DEMO/REPLAY 항상 표시 |

## 공식 자료 교차검증

- [Pelican help](https://pelican.clutch.engineering/help/): Scan sessions의 요청/응답 보존과 export
  경로가 실제 빈 세션 화면 안내와 일치. 실제 export 파일/필드 검증은 세션 부재로 미완료.
- [Pelican features](https://pelican.clutch.engineering/features/): OBD/trips/Shortcuts를 문서화.
  이번 실행에서 Shortcuts 실행과 CarPlay는 미검증.
- [Car Scanner custom PIDs](https://www.carscanner.info/custompids/): header/command/formula로
  정의하는 모델이 사용자 정의 센서 메뉴와 대응. 정의 저장·실차 decode는 이번에 실행하지 않음.
- [Car Scanner recording](https://www.carscanner.info/records/): 개별/통합 graph, CSV/BRC export,
  표시 신호 중심 기록을 설명한다. 우리 제품은 화면 전환과 무관한 원본 기록이 요구되므로
  기록 정책은 그대로 복제하지 않는다. 기록 화면 진입만 직접 확인.
- [ABRP premium](https://abetterrouteplanner.com/premium/): 소비량 모델, 충전·경로 선호도,
  데이터와 이력을 설명한다. 충전/경로 옵션 실측과 일치하지만 예측 정확도/유료권한은 미검증.
- [OBDeleven features](https://obdeleven.com/features): ECU 진단과 차종/플랜 의존성을 설명한다.
  실제 demo ECU 화면은 확인했으나 Golf GTE demo를 Santa Fe 지원 근거로 쓰지 않는다.

## 구현 가능한 명세 단위

1. VehicleProfile: 연식/동력원/사용자 별칭, ECU 목록, 검증된 adapter reference,
   signal-definition revision, dashboard IDs. 수동 등록은 인터넷/VIN 없이 가능해야 한다.
2. SignalCatalogueEntry: 원천/raw 또는 진단/ECU/단위/지원상태/읽기허용 query/출처,
   acquisitionEnabled, recordingEnabled, widgetBindings를 독립 필드로 둔다.
3. SessionIndex: 재실행 후 목록 복원, mode·기간·원천별 샘플수·gap·MARK,
   원본 → 해석값 → CSV → replay 연결 ID. 지도 실패와 UI 이동은 기록에 영향 없어야 한다.
4. DashboardPreset: Numeric/Gauge/Bar/LED/Trend/GPS를 동일 신호에 bind,
   빈값과 stale을 구분하고 Dynamic Type/가로세로/저장복원 UI 테스트를 갖춘다.
5. LocalAnalytics: 전압/전류/시간으로 계산한 에너지와 측정 SOC를 구분한다.
   HEV의 연료/회생/전기 사용량을 하나의 EV 잔여거리 공식으로 합치지 않는다.

기존 Transport/QuerySession/Decoder/Store/Recorder/Editor를 재사용한다. 새 framework 전환은
필요 없다. 경쟁사 내부 코드·PID 데이터베이스·이미지는 제품 자산으로 사용하지 않는다.

## 완료 기준과 순서

- [ ] P0: 앞선 코드 감사의 provenance/원본 replay/기록 순서/허위 10Hz 표시 문제 재현 및 수정.
- [ ] P0: 세션 목록/재실행 복원/CSV/실제 UI replay까지 하나의 소프트웨어 E2E 통과.
- [ ] P0: 차량→ECU→신호→원본/위젯 경로. 같은 SOC Numeric+Gauge/Bar에서 확인.
- [ ] P0: BT4N 실측 GATT와 실제 SOC 응답 이후 10분, 그 뒤 1시간 실차 시험.
- [ ] P1: 활성·지원·우선순위 필터, 로컬 profile 백업/import, 차트 cursor/비교와 마스킹 export.
- [ ] P2: 검증된 신호로 소비량/에너지 분석, 세션 App Intents, 승인 범위 CarPlay 상태 화면.

네 앱 모든 하위 메뉴를 완료했다고 표시하지 않는다. 잔여 조사: Car Scanner custom PID 편집/녹화
파일 재생·export·DTC/freeze/readiness/대시보드 편집 상세, Pelican 실제 scanner/session export/
지도 온보딩/Shortcuts, ABRP 실제 route·충전기·유료이력, OBDeleven 실제 adapter/live data/배터리
검사 및 차종 제한. 차량 제어·DTC 삭제·유료 구매·계정연동은 수행하지 않았다.

## 상태 변경/개인정보

Pelican의 PanameraEHybrid simulation을 선택했고 Car Scanner 마지막 차량 demo를 실행했다.
OBDeleven은 시작할 때 이미 Golf GTE demo였다. 실제 차량값으로 표시하지 않는다.
VIN/계정명/위치 지도 screenshot은 로컬 원본에만 있으며 원격 저장소에 넣지 않았다.
제품 코드·버전 변경 없이 비교 보고서와 비식별 증거만 추가한다.

추가 탐색: Car Scanner 사용자 정의 센서 페이지에 import/export가 있고 현재 목록은 비어 있다.
Pelican Settings 아래에서 OBD scanning, Notifications, Personalization, Performance optimizations,
Data & backups 메뉴를 확인했다. 각 하위 기능의 설정 변경/복원은 아직 미검증이다.
탐색 종료 시 설치된 Telemetry가 0.22.2(18)인 것을 다시 확인했다.
