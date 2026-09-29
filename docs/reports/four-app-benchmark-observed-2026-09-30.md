# 4개 iPhone 차량 앱 실측 벤치마크

실행일: 2026-09-30. 제품 코드 기준: ce5e3d0. iPhone 17 실기기, XCTest 직접 실행.

## 판정

네 앱을 직접 활성화하고 화면·접근성 트리·조작 기록을 확보했다. **전체 기능 검증 완료는 아니다.**
화면 진입, 데모 값 표시, 실제 차량 수집은 별도 증거다. 로그인/유료 기능/전용 하드웨어/실차 전용
기능과 미방문 하위 메뉴는 아래에 남겼다. XCTest 성공도 해당 navigation script 종료만 의미한다.

### Car Scanner 탐색 판정 교정

초기 `carscanner-all.log`의 13회 탭은 화면 제목 `StaticText`만 눌렀고, 캡처를 재확인하니 여러 장이
같은 홈 화면이었다. 이 결과들은 기능별 화면 진입 증거로 세지 않는다. 이후 명시적 데모 상태에서
타일 버튼을 눌러 화면 제목·본문 접근성 트리·스크린샷이 바뀐 경우에만 아래 커버리지에 포함했다.
첫 교정 시도에서 자동화의 홈 판별 조건이 잘못되어 실패한 결과도 성공으로 승격하지 않았다.
최종 직접 화면 증거는 `carscanner-visible-functions.xcresult`, `safe-deep-branches.xcresult`,
`csc-custom-sensor-detail.xcresult`, `csc-sensor-filter-dashboard-add2.xcresult`,
`csc-empty-dashboard-picker.xcresult`다. 앱 메뉴/데모 UI 관찰이지 Car Scanner 데이터 수집이나
싼타페 실차 측정 성공이 아니다. 사용자가 iPhone 잠금을 해제한 직후 한 번은 UI automation mode
초기화가 timeout 되었으나, 후속 실행에서 선택자/화면 식별을 보정한 테스트가 시작되어 통과했다.

설치: Pelican 5.0.3(855), Car Scanner 2.1.46, ABRP 7.1.7(설치 5980, 설정 UI 6006),
OBDeleven 2.12.0(1790149781). ABRP 설치/화면 build 차이는 관찰 사실이며 원인은 미확인이다.

첫 인증 실행은 XCTest 암호 입력 대기로 timeout. 인증 후 entry-authenticated 실행은 새 테스트
파일의 프로젝트 등록 누락으로 기능 증거가 없었다. XcodeGen 갱신 후 entry-inventory부터 실제
앱 순회 및 캡처를 확인했다. details 실행의 Car Scanner 상단 버튼 탐색 실패를 보존했다.
후속 실행에서는 fullscreen gauge를 탭해 버튼을 다시 노출한 후 센서 목록으로 이동했다.
조건문으로 건너뛴 메뉴는 실행 성공으로 계산하지 않았다.

원본 결과: `/tmp/vehicle-benchmark-20260930/` 아래 entry-inventory, menus, deep, branches,
more, data, records, final, config, carscanner-visible-functions, safe-deep-branches,
obdeleven-catalogue-filters, csc-custom-sensor-detail, csc-sensor-filter-dashboard-add2,
csc-empty-dashboard-picker, csc-home-restored의 log/xcresult. 개인 계정/VIN/위치 포함 원본은
Git에 넣지 않았다. 비식별 대표 화면 28장은
[증거 갤러리](evidence/four-apps-20260930/index.html)와
[증거 manifest](evidence/four-apps-20260930/manifest.json)에 SHA256, 시각, test ID로 연결한다.
VIN/계정 이메일/위치/개인 로그가 있는 원본 캡처와 접근성 트리는 Git에 넣지 않았다.

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

## 실기기 메뉴/하위 화면 커버리지

상태는 **OBSERVED**(화면과 컨트롤을 직접 확인), **PARTIAL**(진입/일부 UI만 확인),
**BLOCKED**(계정·구독·실제 장치·차량 필요), **NOT TESTED**(이번에 열지 않음),
**OUT OF SCOPE**(차량 상태 변경 위험 때문에 실행하지 않음)으로 구분한다. 화면 진입만으로 기능 동작을
증명하지 않는다. 같은 앱 안의 접근성 트리에 뒤 화면 항목이 남는 경우에는 화면 제목/캡처를 추가 대조했다.

| 앱 / 화면군 | 상태 | 직접 확인한 범위와 제한 |
| --- | --- | --- |
| Pelican 진입/차고/차량 추가 | OBSERVED | Garage, Offline vehicle 등록 폼, 계정 연결 종류, Simulated vehicles와 Panamera HEV 데모 진입. VIN 제출·계정 연결 안 함. |
| Pelican Logbook | OBSERVED | Documents, Journeys, Records, Scan sessions 및 CarPlay Quick Destinations의 1~4 슬롯. 개인 기록이 보일 수 있는 상세·공유는 열지 않음. |
| Pelican 설정 | OBSERVED | 설정의 전체 스크롤 목록, OBD scanning, Personalization, Performance optimizations, Data & backups 화면. Vehicle scanning 토글은 OFF 상태였고 변경하지 않음. |
| Pelican 스캔/매개변수/내보내기/Shortcuts | BLOCKED / NOT TESTED | BT4N이 연결되지 않았고 스캔이 비활성화되어 실제 세션이 없다. 로그 내보내기도 미실행. 제조사 명령 실행을 포함할 수 있는 Shortcut은 열거나 실행하지 않음. |
| Car Scanner 홈 메뉴 | OBSERVED | 13개 타일을 여러 번의 보정된 실행으로 각각 실제 화면에 진입. 첫 잘못된 홈 반복 캡처는 제외. Settings와 Custom Sensors는 별도 테스트 결과로 교차 확인. |
| Car Scanner Dashboard | OBSERVED | 3페이지 이동, HUD, Gauge/숫자 계기, 빈 2/3 페이지, 페이지 관리 메뉴를 관찰. 기존 게이지 두 번 탭은 User-defined/센서 선택/유형 변경/이동/스타일 복사 메뉴를 열고, 빈 페이지 두 번 탭은 `선택 안 함`이 기본인 `센서 선택` 목록을 연다. 아무 signal도 bind하지 않음. |
| Car Scanner Live Data / All Sensors | OBSERVED | 차트 화면 진입 전에 개별/통합 선택창이 나타남. 두 차트 모드와 스크롤 센서 목록을 확인. 필터 아이콘은 검색/`보이는 센서만 업데이트` 체크 옵션을 노출했다. 옵션을 변경하지 않았고 값은 데모다. |
| Car Scanner DTC / Freeze Frame / Readiness / ECU ID | PARTIAL | DTC 설명 및 읽기/삭제 선택, Freeze Frame의 #0/미지원 또는 데이터 없음, readiness 데모 모니터, ECU 모듈 선택 및 읽기/삭제 버튼을 확인. 읽기 요청과 삭제는 실행하지 않음. |
| Car Scanner My Car / Statistics / Acceleration / Emissions | PARTIAL | 차량 프로필, 기간 선택과 통계 범주, 데모 가속 결과, readiness 상태 화면을 확인. 민감한 프로필 값은 보존하지 않고 데모값을 실차값으로 해석하지 않음. |
| Car Scanner Data Recording | PARTIAL | 기록·위치·반올림 스위치, 가져오기, 기존 사용자 세션 항목을 확인. 해당 기존 로그의 재생/내보내기/삭제를 하지 않음. |
| Car Scanner Settings / Sensors | PARTIAL | OBDII ELM327/Bluetooth LE 설정, 차량 프로필·단위·Dashboard·차량 옵션·연비·ABRP·Sensors·백업·터미널·사용자 정의 코딩 메뉴, Custom Sensors 편집기를 확인. `+`는 기본 `New sensor` 행을 즉시 생성하고 행 탭은 이름/약칭/명령어/헤더, 공식·바이트·비트·Action PID·VW TP 2.0 디코딩, 공식, 최소/최대, 단위, 우선순위/역할, init/exit 명령 및 text mapping 필드를 연다. 값 입력/Test/OK 저장은 하지 않았다. 임시 빈 행은 삭제했고 목록이 비었음을 검증했다. |
| ABRP 홈/경로 설정 | PARTIAL | 지도+경로 패널, 목적지 입력, Home/Work/저장 목적지, 차량 추가, plan 선택을 화면에서 확인. 충전·경로·개인정보 옵션과 차량 목록은 직접 확인. 주소 입력/경로 계산/길안내는 시작하지 않음. |
| ABRP 계정/유료/차량 데이터/주행 이력 | BLOCKED / NOT TESTED | 로그인 상태가 아니고 Premium/외부 차량/실시간 경로를 사용하지 않음. Home/Work 주소 또는 저장 경로가 노출될 수 있는 분기는 개인정보 보호를 위해 열지 않음. |
| OBDeleven Home/Vehicle/Control Units | OBSERVED | Golf GTE 데모, 연결 안 됨 상태, ECU 목록·검색·상태 배지와 차량 기능 타일을 확인. 표시된 Faulty 배지는 데모이며 사용자 차량 고장이 아님. |
| OBDeleven Engine/Faults/Live Data | PARTIAL | Engine 메뉴의 Faults, Advanced Live Data, ID, coding/adaptations/output/basic setting 항목을 확인. live data는 연결 요구 화면까지 확인했고 ECU 값은 얻지 못함. 오류 삭제/출력 테스트·코딩은 안 함. |
| OBDeleven Apps 카탈로그 | OBSERVED / OUT OF SCOPE | All/Adjustment/Workshop/Retrofit 필터, 검색/정렬과 데모 항목 목록을 확인. 각 항목은 차량 설정·동작을 바꿀 수 있어 상세 활성화·크레딧 구매·실행은 OUT OF SCOPE. |
| OBDeleven 실제 장치/차량/유료 범위 | BLOCKED | 데모 외 OBD 장치 및 연결된 차량이 없음. 브랜드·차량·iOS 앱·플랜별 기능 지원은 화면 목록만으로 판정할 수 없음. |

## 우선순위와 제품 적용안

| 우선순위 | 적용할 패턴 | 완료 기준 |
| --- | --- | --- |
| P0 | Car Scanner의 자유 Dashboard, 다중 페이지, HUD, 개별/통합 차트와 signal binding | 위젯 추가/삭제/정렬/복원 자동 UI 테스트. 센서 출처와 `LIVE/DEMO/REPLAY`를 항상 구별. |
| P0 | Car Scanner/Pelican의 연결 상태 및 기록 세션 분리 | BLE 연결·ECU 응답·신호 stale 상태를 분리하고, 화면에 노출되지 않은 raw CAN/진단 원본도 UI와 독립해 기록. 세션 복원·CSV·재생 검증. |
| P0 | Vehicle → ECU/profile → signal → 위젯 흐름 | 지원/미지원/timeout을 0과 구분. 사용자 정의 PID/신호 설정은 읽기 allowlist와 버전·출처를 저장. |
| P1 | Pelican의 차고/기록 분류와 OBDeleven ECU 카탈로그 | Vehicle/ECU capability 목록은 읽기 전용으로 표현하고 실제 수집 source·지원 증거를 동봉. |
| P1 | Car Scanner의 숫자/비용/에너지 통계와 기록 내보내기 | 측정값·계산값·사용자 입력을 구별하고 CSV 원본과 조회/재생 값을 교차 검증. |
| P2 | ABRP의 EV 경로/충전기 정보 및 CarPlay | EV 범위가 확인된 이후 오프라인 계측과 분리된 선택 기능으로만 설계. ABRP 계정/OAuth/서버·지도 경로를 복제하지 않음. |
| 제외 | DTC 삭제, ECU coding/adaptation, One-Click Apps, actuator/output tests, Security Access | 현재 telemetry 제품은 관측 전용. 경쟁 앱의 화면에 존재한다는 이유로 추가하지 않음. |

Car Scanner 공식 기록 설명은 화면에 표시되는 수치와 응답에 같이 포함되는 수치를 기록하고, 숫자값 위주로 저장한다고 설명한다.
이는 해당 앱의 동작 관찰에는 참고하지만, 우리 제품은 화면 이동/레이아웃과 무관하게 원본 CAN·진단 응답·GPS를 모두 저장해야 하므로
기록 정책으로 그대로 채택하지 않는다. 해당 문서는 기록을 disconnect 또는 record off 시 저장하며 iOS export에서 CSV/BRC를 안내한다.

최종 추가 직접 확인: Custom Sensors의 `+` 동작은 별도 폼을 바로 열지 않고 기본 행을 만든다. 해당 행을 눌러 편집기까지 열어 필드 구성을 확인했다.
이 탐색에서만 생성한 빈 행은 확인 후 삭제했고 목록 비움을 다시 확인했다. All Sensors의 필터 아이콘은 검색과 `보이는 센서만 업데이트` 체크 옵션을 노출한다.
Dashboard 2/3의 빈 공간을 두 번 탭하면 `선택 안 함`이 기본인 `센서 선택` 목록이 열린다. 위젯 바인딩은 변경하지 않았다.

## 공식 문서 교차검증과 적용 한계

- [Pelican OBD scanning](https://pelican.clutch.engineering/scanning/): OBD/PID/DTC와 BTLE·Wi-Fi·Classic Bluetooth를 설명한다. 현재 표는 일반 “ELM327 Bluetooth OBD2 Scanner” BTLE를 미지원으로 표시하고, NANICAR BT4N은 모델명으로 나열하지 않는다. 따라서 BT4N 호환 여부는 미확인이다. 5분 초과 scan은 구독/ScanPass가 필요하고 Wi-Fi scanner와 wireless CarPlay 동시 사용 제한이 안내된다.
- [Pelican help](https://pelican.clutch.engineering/help/): 활성 scan에서 보낸/받은 OBD 명령을 로그로 보관하며 로그에 VIN이 들어갈 수 있다고 명시한다. 실기기 UI에서 Scan sessions는 빈 상태였고, 내보내기는 실행하지 않았다.
- [Car Scanner recording](https://www.carscanner.info/records/): 화면 표시값 및 연관 응답값 기록, 별도/통합 그래프, CSV/BRC export와 BRC import 제한을 설명한다. 현 iOS 화면에서 기록 설정·기존 파일 목록은 보았으나 최신 앱의 저장·재생·공유 동작은 직접 검증하지 않았다.
- [Car Scanner custom PID](https://www.carscanner.info/custompids/): 사용자 정의 PID 문서와 앱의 Custom Sensors 분류를 교차 참고한다. 편집/실차 응답은 미검증이며 OEM 전용 정의를 복사하지 않는다.
- [ABRP Premium](https://abetterrouteplanner.com/premium/): EV 경로 최적화, 차량 live data, 충전기 상태, 트래픽/날씨, 이력과 CarPlay를 구분한다. 본 차량은 HEV이고 경로를 계산하지 않았으므로 정확성/지원 여부는 미검증이다.
- [OBDeleven features](https://obdeleven.com/features), [One-Click Apps](https://obdeleven.com/one-click-apps): 차량/앱/iOS/플랜별 지원 차이를 안내하고 One-Click Apps가 차량 기능을 조정·활성·비활성화하는 코딩 기능임을 명시한다. 직접 화면에서도 카탈로그와 필터까지만 확인하고 실행하지 않았다.

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

네 앱 모든 기능의 동작 시험을 완료했다고 표시하지 않는다. 잔여 조사 우선순위:

1. P0: Car Scanner custom PID 편집기 필드는 관찰했지만 명령 해석/저장/센서 응답·import/export는 미검증. 기존 사용자 로그 재생은 별도 비식별 샘플을 확보한 뒤 검증한다. 사용자 기록은 열거나 공유하지 않았다.
2. P0: NANICAR BT4N을 실제 차량과 분리/재연결해 GATT, Mode 01, 제조사 SOC/전압 후보를 확인. Pelican과 다른 OBD 앱은 동시에 scanner에 연결할 수 없으므로 순차 비교.
3. P1: Car Scanner의 각 Settings 하위 항목·센서 필터/단위·편집 페이지 템플릿은 값을 바꾸지 않는 범위에서 계속 조사.
4. P1: Pelican의 실제 scanner pairing, 파라미터 정의/refresh, scan-session export는 사용자가 별도 비식별 로그를 승인하거나 테스트 차량/장치가 연결될 때만 검증.
5. P1: ABRP의 목적지·충전기 결과·저장계획·Premium/실시간 차량 경로는 계정, 네트워크 및 위치/경로 데이터 처리 동의가 있을 때 검증.
6. P1: OBDeleven 실제 장치와 차량 연결, live-data 값, DTC/배터리 확인 기능은 지원 차량과 요금제 증거가 있을 때 검증.

자동화 재시도 참고: `carscanner-config-branches-resume.log`는 iPhone unlock 직후 UI automation mode timeout으로
중단됐지만, 뒤이은 실행에서 실제 화면 테스트가 시작되어 custom sensor editor, visible-only filter,
Dashboard 2/3 sensor picker를 관찰했다. 접근성 label/identifier 혼용으로 실패한 임시 테스트는 화면 증거로 세지 않았고,
최종 성공 테스트에서는 label 조건을 보정했다. 암호/코드는 채팅으로 받지 않았다.

실행하지 않은 작업: 차량 제어, coding/adaptation, One-Click App 실행, DTC 삭제, output test, 구매, 로그인/계정 연결, 사용자 위치/저장 목적지 조회. 이를 필요로 하는 기능은 이번 프로젝트 목표에 포함하지 않는다.

## 상태 변경/개인정보

Pelican의 PanameraEHybrid simulation을 선택했고 Car Scanner 마지막 차량 demo를 실행했다.
OBDeleven은 시작할 때 이미 Golf GTE demo였다. 실제 차량값으로 표시하지 않는다.
VIN/계정명/위치 지도 screenshot은 로컬 원본에만 있으며 원격 저장소에 넣지 않았다.
제품 코드·버전 변경 없이 비교 보고서와 비식별 증거만 추가한다.

추가 탐색: Car Scanner Settings → Sensors → Custom Sensors에서 사용자 정의 센서 목록/가져오기·내보내기 진입점을 확인했다. 실제 PID를 저장하지 않았다.
Pelican Settings의 OBD scanning, Personalization, Performance optimizations, Data & backups 각 화면과 Logbook의 Documents/Journeys/Records를 열어 보았다. 설정 토글과 backup/export 실행은 미검증이다.
OBDeleven One-Click Apps 카탈로그의 All/Adjustment/Workshop/Retrofit, 빈 검색 및 정렬 UI를 직접 확인했고 아무 앱도 활성화하지 않았다.
Car Scanner의 빈 sensor add 동작으로 만들어진 placeholder 1개는 탐색 직후 삭제했고, 후속 테스트 사전 조건에서 빈 목록으로 복원됨을 확인했다. 사용자 정의 PID나 dashboard signal binding은 저장하지 않았다.
탐색 종료 시 설치된 Telemetry가 0.22.2(18)인 것을 다시 확인했다.
