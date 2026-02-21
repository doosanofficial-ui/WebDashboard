# P3-3 Immediate Next Actions (2026-02-21)

목적: P3-3(백그라운드 위치 uplink)의 미완료 항목을 오늘 바로 실행 가능한 3개 작업으로 고정한다.

## Action 1 — Android FGS 구현 착수 기준선 검증

- 목표: Android 트랙 구현 전, 현재 모바일 스캐폴드가 기준 상태인지 확인
- 실행 명령:
  - `node mobile/scripts/validate-mobile-scaffold.js`
  - `cd mobile && npm test -- --runInBand --silent`
- 완료 기준:
  - 스캐폴드 검증 통과
  - 테스트 통과 또는 실패 원인 1회 분류(테스트/환경/기능)
- 산출물:
  - 본 문서의 실행 결과 섹션 업데이트

## Action 2 — Android FGS 구현 태스크 분해(코드 변경 단위)

- 목표: `android-manifest-fgs-scaffold.xml` 기준으로 실제 구현 태스크를 코드 단위로 확정
- 대상 파일:
  - `mobile/scripts/android-manifest-fgs-scaffold.xml`
  - `mobile/src/telemetry/gps-client.js`
  - `mobile/src/App.js`
- 완료 기준:
  - 아래 4개 코드 변경 단위를 작업 항목으로 확정
    1. `LocationForegroundService` 추가 (notification channel + `startForeground`)
    2. `RNAndroidLocationBridge` 추가 (`startBackgroundLocation`, `stopBackgroundLocation`)
    3. Android background location 권한 요청 분기 추가
    4. `meta.bg_state`가 background 구간에서 안정적으로 기록되는지 검증 경로 확정
- 확정 작업 단위(2026-02-21 잠금):
  1. `mobile/src/telemetry/gps-client.js`
     - `requestLocationPermission`에 `ACCESS_BACKGROUND_LOCATION` 요청 분기 추가
     - 상태: DONE (2026-02-21)
  2. `mobile/src/App.js`
     - Android 전용 background 모드 토글 상태(`androidBgPilot`) 추가
     - `startGpsWatch` 호출 시 OS별(`iosBackgroundMode`/`androidBackgroundMode`) 옵션 전달
     - 상태: DONE (2026-02-21)
  3. Android 네이티브 신규 파일(로컬 생성 대상)
     - `LocationForegroundService.kt`
     - `RNAndroidLocationBridge.kt`
     - 상태: IN_PROGRESS (소스 스캐폴드 추가 완료, 네이티브 프로젝트 연결 대기)
  4. `mobile/src/telemetry/protocol.js`
     - `meta.bg_state`의 foreground/background 기록 회귀 검증(코드 변경 없이 테스트 기준 고정)
     - 상태: DONE (검증 경로 잠금)

## Action 3 — 30분 백그라운드 검증 실행 계획 잠금

- 목표: iOS 템플릿을 Android에도 동일 기준으로 적용 가능한 실행 계획으로 잠금
- 참조 문서:
  - `docs/reports/ios-bg-30min-template.md`
  - `docs/e2e-platform-checklist.md`
- 완료 기준:
  - Android 실행 메타/측정값/판정 기준을 동일 포맷으로 확정
  - 필수 로그 파일(`gps_<session>.csv`, `events_<session>.csv`) 추출 절차를 체크리스트에 반영
- 확정 실행 절차(2026-02-21 잠금):
  1. 서버 실행: `cd server && HOST=0.0.0.0 python app.py`
  2. 모바일 실행: `cd mobile && npm run android`
  3. 로그 추출: `server/logs/gps_<session>.csv`, `server/logs/events_<session>.csv`
  4. 판정 기입: `docs/reports/android-bg-30min-template.md`에 기록
  5. 분석: `python3 scripts/analyze_ios_bg_session.py --gps-csv ... --events-csv ...`

## 실행 결과 (업데이트용)

- Action 1:
  - 상태: DONE
  - 결과:
    - `node mobile/scripts/validate-mobile-scaffold.js` 통과
    - `cd mobile && npm test -- --runInBand --silent` 통과 (2 suites, 15 tests)
- Action 2:
  - 상태: IN_PROGRESS
  - 결과:
    - DONE: Android background location 권한 요청 분기 추가
      - `mobile/src/telemetry/gps-client.js`
      - `mobile/src/App.js`
    - IN_PROGRESS: Android 네이티브 브리지/서비스 소스 스캐폴드 추가
      - `mobile/native-android-bridge/LocationForegroundService.kt`
      - `mobile/native-android-bridge/RNAndroidLocationBridge.kt`
      - `mobile/scripts/apply-android-location-background.sh`
    - TODO: 생성된 `android/` 프로젝트에 반영 후 ReactPackage 등록 및 런타임 검증
- Action 3:
  - 상태: DONE
  - 결과:
    - `docs/reports/android-bg-30min-template.md` 신규 추가
    - `docs/e2e-platform-checklist.md` Android 30분 시나리오 섹션 추가

## Action 4 — iOS Preflight Smoke (실기기 전 서버 경로 검증)

- 목표: iPhone 실기기 30분 검증 전에 서버/WS/GPS/MARK 파이프라인 정상 동작을 선확인
- 실행 항목:
  1. `GET /api/ping`
  2. `WS /ws` 프레임 수신 + ping/pong
  3. 샘플 GPS uplink(meta 포함) 전송
  4. MARK 이벤트 전송
  5. CSV 기록 확인 + 분석 스크립트 실행
- 상태: DONE (2026-02-22)
- 결과 산출물:
  - `docs/reports/ios-preflight-smoke-2026-02-22.md`

## Action 5 — iOS 30분 실측 실행용 폼 고정

- 목표: 현장 실측 중 누락 없이 체크/기록할 수 있는 운영용 폼 제공
- 상태: DONE (2026-02-22)
- 결과 산출물:
  - `docs/reports/ios-bg-30min-execution-form.md`
  - `docs/e2e-platform-checklist.md` iOS 섹션 링크 반영

## 실기기 부재 모드 (현재 세션 적용)

- 제약:
  - Android 실기기 부재로 30분 실주행/백그라운드 실측은 수행하지 않음
- 대신 완료한 항목:
  - JS 권한 분기/상태 전달 baseline 구현
  - Android 네이티브 브리지/서비스 소스 스캐폴드 및 적용 스크립트 추가
  - 문서/체크리스트/리포트 템플릿 잠금
- 잔여 항목:
  1. `npm run init-native && npm run android:setup-bg` 실행
  2. Android 프로젝트에서 ReactPackage 등록 및 Manifest 병합
  3. 에뮬레이터 또는 실기기에서 30분 시나리오 실측 후 보고서 기입
  4. iPhone 실기기 30분 시나리오 실측 후 `ios-bg-30min-execution-form` 작성
  5. `docs/reports/ios-bg-30min-template.md` 최종 판정 반영
