# 사내 배포 상용화 진단 (2026-09-19)

이 문서는 9월 19일 당시 진단이다. 이후 Xcode 발견·Git 복구·네이티브 구현의
최신 상태는 [9월 23일 체크포인트](native-milestone-2026-09-23.md)를 참고한다.

## 판정과 범위

**현재 판정: 상용 배포 불가. 웹 MVP와 모바일 스캐폴드 단계.**
현재 파일과 이번 실행 결과를 근거로 작성했다. 2월의 PASS나 서버 실행 기록을
현재 설치/운영 증거로 재사용하지 않는다.

- 사용자 확정 배포 대상: 사내 테스트 엔지니어용 설치·배포.
- 서버: Windows 노트북, Vector VN1640A 및 기존 계측 도구 연동.
- 우선 검증 기기: iPhone 17 / iOS 26.6.2 (사용자 제공, 기기 조회로는 미검증).
- 전체 목표: CAN 10Hz, 게이지/그래프, GPS, 지도/로드뷰, 재연결, 기록,
  화면 잠금 중 위치 수집, 사내 설치/복구, CarPlay. Android도 후속 범위에 유지한다.
- ECU 제어는 기존 PRD대로 범위 밖이다.

## 현재 실행 환경

원래 경로 Documents/VScodePrj/WebDashboard는 없다. 실제 소스는 Finder 표시명 기준
Documents/문서 - 백두산의 MacBook Pro/VScodePrj/WebDashboard 아래에 있다.
파일시스템 한글은 분해형이고 공백 일부는 NBSP이다.

- .git/HEAD, .git/index, .github/workflows/reusable-smoke.yml이 dataless 상태다.
  내용이 로컬에 없어 Git 상태/이력/CI 원문 검증이 대기했다.
- brctl download로 프로젝트 및 Git/CI 폴더 다운로드를 요청했으나
  재조회 시에도 dataless였다. 명령 종료 코드 0을 복원 성공으로 보지 않는다.
- 이번 진단의 대기 중 Git/cat 프로세스는 종료했다. Git 초기화, 이력 재작성,
  커밋, 푸시는 수행하지 않았다. 기존 작업과의 Git diff 검증은 복원 후 필요하다.
- /Applications/Xcode.app가 없으며 xcodebuild -version은 Command Line Tools만
  활성화되어 있다는 오류로 실패했다. 현 Mac에서 iOS 빌드/설치 증거는 없다.
- 기존 server/.venv/bin/python3는 사라진 Xcode 내부 Python을 가리킨다.
  서버용 Python 3.11+ 환경을 새로 준비해야 한다.
- 원본 mobile/node_modules 일부도 dataless다. 현재 소스와 잠금파일을 임시 검증
  폴더로 복사해 npm ci --ignore-scripts로 설치했다. 원본 의존성은 변경하지 않았다.

## 재현 및 수정

검사 명령: `node --experimental-vm-modules --test scripts/tests/gps-data-integrity.test.mjs`

실제 웹/RN GPS 모듈을 수정 없이 로드하며 OS 위치 API만 대체한다.
RN 출력은 실제 createGpsPayload를 거쳐 JSON으로 직렬화한 본문을 검사한다.

- 최초 16개: 4 PASS / 12 FAIL.
- 실패 내용: null 좌표의 0 변환, 범위 밖 좌표 허용, 미수신값의 0 또는 과거값
  전송, 잘못된 heading 범위, iOS 권한 API 호출 방식 불일치.
- 수정 후: 16 PASS / 0 FAIL.
- 실제 정지 속도 0, 북쪽 방향 0, 유효한 숫자 좌표 (0, 0)은 보존한다.
- 새 fix의 미수신 항목은 null, 숫자 표시는 -이다. 새 이벤트 자체가 없으면
  마지막 fix를 유지하되 stale로 표시한다.
- 이전의 무조건 last-value 유지 수정은 과거 속도를 새 측정값으로 기록할 수
  있었다. 수신 원본과 표시의 의미를 바로잡았다.
- 실제 설치 잠금파일의 geolocation 3.4.0 소스로 콜백 API를 확인했다.
  requestAuthorization("always")와 Promise 반환 가정을 제거했다.
  권한 수준은 setRNConfiguration, 결과는 success/error 콜백으로 처리한다.
- 이 success 콜백은 Always 권한 확보나 30분 BG 동작의 증거가 아니다.
  설치 브리지, 권한 수준, Background Modes와 실기기 로그 확인이 별도로 필요하다.
- 브리지 누락을 일반 GPS로 대체하던 경로에 3개 검사 추가:
  수정 전 3 FAIL, 수정 후 전체 19 PASS.
- BG 요청 시 브리지가 없으면 시작을 거부하고 gps-bg-unavailable로 표시한다.
  반환값은 시작 요청/등록 결과이며 네이티브 서비스 지속 실행의 보장은 아니다.

## 남은 주요 결함

| 우선순위 | 현재 증거 | 해결 및 완료 증거 |
|---|---|---|
| P0 | RN 0.76.7, Metro config ^0.84.0, init-native의 latest 사용 | 지원되는 단일 RN/React/CLI/Metro 조합, 깨끗한 설치에서 Debug/Release 빌드 |
| P0 | app.json은 TelemetryMobile, AppDelegate는 TelemetryMobileNative | 등록명 일치와 실제 앱 실행 |
| P0 | pbxproj에 RNIosLocationBridge 참조 없음 | 파일 복사 외 Compile Sources 연결과 실제 모듈 로드 |
| P0 | native 위치 timestamp 미전달, protocol은 송신 시 Date.now() 사용 | 측정/수신/저장 시각 분리, 지연 재전송 시 측정 시각 불변 |
| P0 | 큐가 send 성공을 서버 기록 성공으로 취급 | 서버 영속 기록 ACK, event ID 중복 제거, 재시작/단절 시험 |
| P0 | 저장 오류 무시, init/flush 경쟁 가능, 배치 200개 제한 | 저장 실패 가시화·직렬화, 전체 큐 재전송 및 overflow 측정 |
| P0 | WS JSON 후 dict 확인 없음, GPS 필드 검증 부족 | 잘못된 프레임 거부 후에도 정상 10Hz 유지 |
| P0 | 초 단위 세션명과 CSV w 모드 | 빠른 재시작에도 덮어쓰기 방지, 디스크 오류 처리 |
| P0 | 인증 없는 LAN API, 광범위 CORS | 장치 페어링, TLS/Origin 정책, 비허용 기기 차단 검증 |
| P0 | sw.js가 API/외부 응답까지 cache-first 저장 | 정적 자원만 캐싱, API 실패에 HTML 반환 금지, 업데이트 시험 |
| P0 | 현재 30분 BG/Windows 설치 증거 없음 | 해당 실측 및 설치 보고서 |
| P1 | 지도는 환경변수 기반, 현 세션 렌더 검증 없음 | 허용 origin과 모바일 지도/로드뷰 동기화 실측 |
| P1 | 실제 CAN adapter는 문서만 존재 | 선택한 경로 연결 후 VN1640A 실측 |
| 필수 후속 | CarPlay 구현/권한 증거 없음 | 지원 카테고리/권한 확인 후 템플릿과 기기 검증 |

현재 잠금파일로 실행한 npm audit --json 결과:
critical 2 / high 14 / moderate 9 / low 1, 총 26건.
이는 의존성 경고 집계이며 모두 앱에서 악용 가능하다는 뜻은 아니다.
직접 영향 패키지에는 react-native와 community CLI가 있다.
자동 force 업데이트는 하지 않았다. 영향 평가와 호환 업그레이드 후
빌드·회귀 검증을 배포 조건으로 둔다.

## 검증 경계

- 독립 회귀 검사: 19 PASS, 네이티브 하드웨어는 모의 입력.
- 기존 Jest: 2 suites / 16 tests PASS. 최신 수정 소스를 잠금파일 기반 임시 환경에서 검사.
- 플랫폼 문서 검사와 모바일 파일 존재 검사 PASS.
- iOS 컴파일/설치, 화면 잠금 수집, 실차 CAN, Windows 설치, 지도 실화면,
  단절 후 서버 영속 기록은 이 검사로 증명하지 못한다.
- 버전 0.1.0 유지. 수정 수용 및 Core/통합 증거를 확보해 커밋과 결합한 뒤
  버전을 올린다. 현재는 패키지/ZIP 생성, 배포, 상용화 완료 처리 없음.

## 다음 실행 순서

1. iCloud 파일 복원 후 기존 변경과 diff 대조 및 커밋 경계 확정.
2. 빌드 체인/등록명/브리지 연결 고정, 현재 iOS를 지원하는 Xcode로 실기기 설치.
3. 측정시각·ACK·영속 큐·수신 검증 보강 후 iPhone 17에서 잠금/재연결 실측.
4. Windows 설치/실차 adapter/지도/배터리·발열 및 CarPlay 검증 진행.

전체 완료 조건: [사내 배포 계획](../production-plan.md).

## 공식 근거

- [Geolocation API](https://github.com/michalchudziak/react-native-geolocation#requestauthorization): 콜백 기반 권한 요청.
- [W3C Geolocation](https://www.w3.org/TR/geolocation/): 이벤트 기반 수신과 페이지 가시성 조건.
- [Apple 백그라운드 위치](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background): 네이티브 수집 조건.
- [Apple Xcode 지원표](https://developer.apple.com/support/xcode/): Mac/iOS/SDK 지원은 설치 전 표와 실제 기기 인식으로 확인.
- [Apple CarPlay](https://developer.apple.com/carplay/): 지원 카테고리와 entitlement 경로. 일반 대시보드의 자동 변환으로 간주하지 않는다.
