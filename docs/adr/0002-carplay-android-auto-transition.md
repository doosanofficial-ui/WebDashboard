# ADR-0002: CarPlay / Android Auto 전환 전략

- Status: Accepted
- Date: 2026-02-21
- Decision Drivers:
  - 차량 투영 플랫폼(Apple CarPlay, Google Android Auto) 공식 지원
  - 기존 WebDashboard / React Native 자산 최대 재사용
  - 운전자 방해 최소화(Driver Distraction) 정책 준수
  - 팀 역량(JS/TS 중심) 및 심사/배포 리스크 최소화

## Context

- ADR-0001에서 React Native + Native Bridge를 모바일 런타임으로 결정했다.
- 다음 단계(Phase C)는 CarPlay / Android Auto 화면 투영이다.
- 두 플랫폼은 각각 Apple CarPlay entitlement 승인과 Android Auto 카테고리 요건을 요구하며,
  렌더 방식·UX 규칙·심사 정책이 상이하다.
- 어느 범위까지 공통 JS 레이어를 재사용할 수 있는지와 네이티브 전환 범위를 명확히 해야 한다.
- 관련 문서: [`docs/platform-matrix.md`](../platform-matrix.md) §C, §Gate C

## Constraints

1. **Apple CarPlay**
   - `com.apple.developer.carplay-*` entitlement 사전 신청 및 Apple 승인 필요
   - CarPlay Navigation / Communication / Audio 등 제한된 카테고리 내에서만 앱 진입 허용
   - CPTemplate 기반 선언형 UI만 허용 — WebView·Custom OpenGL 렌더링 불가
   - 운전 중 최대 터치 상호작용을 최소화해야 하는 Driver Distraction Guidelines 준수 의무
   - 개인정보 목적 고지(위치·OBD) 심사 통과 필요

2. **Android Auto**
   - Google Play 대시보드에서 Android Auto 카테고리 지정(Navigation, Parking, EV charging 등)
   - `androidx.car.app` 라이브러리(Car App Library) 사용 — 임의 View 렌더링 불가
   - Android for Cars App Quality Guidelines 준수(표시 가능 항목·터치 영역 크기 등)
   - 개발 단계: Head Unit Emulator(DHU) 검증 → Google Play 심사

3. **공통**
   - 두 플랫폼 모두 앱 내 WebView를 투영 화면으로 사용하는 것은 정책상 불허
   - React Native의 기존 JS 비즈니스 로직(상태관리·WS·GPS 큐)은 재사용 가능하나,
     투영 화면 UI 자체는 네이티브 템플릿으로 별도 구현해야 함

## Reuse Scope (공통 JS 재사용 가능 범위)

| 레이어 | 재사용 가능 여부 | 비고 |
|---|---|---|
| WS 연결 / 재연결 / store-and-forward 큐 | ✅ 재사용 | React Native JS 레이어 그대로 사용 |
| GPS 위치 상태머신 / bg uplink | ✅ 재사용 | Native Bridge(위치 권한) 연결 유지 |
| 신호 파싱 / 스케일링 (signals.json) | ✅ 재사용 | 데이터 모델 변경 없음 |
| MARK 이벤트 / 이벤트 큐 | ✅ 재사용 | 투영 화면 버튼과 브리지로 연결 |
| 게이지 렌더 / Canvas 그래프 | ❌ 재사용 불가 | CarPlay CPTemplate / Car App Library로 대체 |
| 지도 / 로드뷰 WebView | ❌ 재사용 불가 | 투영 화면에서 WebView 렌더 불허 |
| PWA manifest / Service Worker | ❌ 무관 | 투영 컨텍스트에서 비활성화 |

## Native Transition Scope (네이티브 전환 필수 범위)

| 기능 | iOS (CarPlay) | Android (Android Auto) | 비고 |
|---|---|---|---|
| 투영 화면 진입 / 세션 핸들링 | `CPApplicationDelegate` 구현 | `Session` / `Screen` 구현 | 네이티브 필수 |
| UI 템플릿 (속도/yaw/경고 카드) | `CPInformationTemplate` / `CPListTemplate` | `MessageTemplate` / `ListTemplate` | 네이티브 필수 |
| 투영 연결 상태 감지 | `CPSessionConfiguration` | `CarContext` | 네이티브 필수 |
| 폴백 화면 전환 (모바일 복귀) | `CPApplicationDelegate` 세션 종료 이벤트 | `Session.onDestroy` | 네이티브 + JS 브리지 |
| 위치 권한 (always) | iOS native (already in ADR-0001) | Android FGS (already in ADR-0001) | 기존 브리지 재사용 |
| WS 데이터 수신 / 상태 동기화 | JS 레이어 → Native Bridge emit | JS 레이어 → Native Bridge emit | 브리지 추가 필요 |

## Options

### Option A: React Native + CarPlay/Android Auto 전용 네이티브 모듈 (권장)

- 설명:
  - JS 레이어(WS/GPS/큐)는 React Native에서 그대로 운용
  - CarPlay 세션 핸들링 및 CPTemplate 렌더는 Swift 네이티브 모듈로 분리
  - Android Auto Car App Library는 Kotlin 네이티브 모듈로 분리
  - 두 모듈은 React Native Bridge를 통해 JS 상태 변경을 구독하고 투영 화면에 반영
- 장점:
  - ADR-0001 결정과 일관성 유지, 기존 자산 최대 활용
  - 투영 UI는 플랫폼 정책을 완전히 준수하는 네이티브 템플릿으로 구현
  - 폴백(투영 → 모바일 화면) 상태머신을 JS에서 중앙 관리 가능
- 단점:
  - iOS Swift + Android Kotlin 브리지 모듈 추가 유지보수 비용
  - CarPlay entitlement 승인 대기 기간 리스크

### Option B: Full Native (별도 iOS/Android 투영 앱)

- 설명:
  - React Native 없이 iOS와 Android 각각 네이티브 앱 신규 개발
- 단점:
  - ADR-0001 결정 번복 및 기존 JS 자산 재사용 불가
  - 이중 코드베이스 유지보수 비용 대폭 증가

### Option C: React Native + react-native-carplay 외부 라이브러리

- 설명:
  - 오픈소스 `react-native-carplay` / `react-native-android-auto` 라이브러리 활용
- 단점:
  - 라이브러리 유지보수 상태 불확실, 플랫폼 정책 업데이트 추종 리스크
  - 커스터마이징 한계 및 CPTemplate 신규 API 지연 지원 가능성

## Recommendation

- **Option A (React Native + 전용 네이티브 모듈)** 채택
  - ADR-0001 결정(React Native + Native Bridge)과 연속성 유지
  - JS 비즈니스 로직 자산을 최대 재사용하면서 투영 화면은 플랫폼 정책 완전 준수
  - 외부 라이브러리 의존 없이 브리지를 직접 제어하여 장기 유지보수 안정성 확보

## Decision

- 채택안: **Option A (React Native + 전용 네이티브 모듈)**
- 결정일: 2026-02-21
- 결정자: Product/Engineering
- 근거:
  - ADR-0001의 React Native 결정 위에 자연스럽게 확장
  - 플랫폼별 투영 화면은 네이티브 템플릿으로 구현해 심사 리스크 최소화
  - JS 상태 레이어(WS/GPS/큐)는 변경 없이 재사용

## Phase-Gate 단계별 백로그

### Phase C-1: 요건 검증 및 승인 (Gate C-1)

목표: 투영 플랫폼 진입 요건을 확정하고 블로커를 제거한다.

| ID | 항목 | 산출물 | 완료 기준 |
|---|---|---|---|
| C1-1 | CarPlay entitlement 신청 | Apple 신청서, 승인 확인 메일 | entitlement 부여 확인 |
| C1-2 | Android Auto 카테고리 지정 | Google Play Console 설정 스크린샷 | 카테고리 승인 완료 |
| C1-3 | Driver Distraction 정책 검토 | 준수 항목 체크리스트 | 팀 합의 완료 |
| C1-4 | 위치/OBD 개인정보 고지 문안 작성 | Privacy Notice 초안 | 법무 검토 통과 |

Gate C-1 Pass Criteria:
- CarPlay entitlement 승인 완료
- Android Auto 카테고리 지정 및 내부 테스트 트랙 활성화
- Driver Distraction 체크리스트 팀 합의

### Phase C-2: 핵심 투영 UI PoC (Gate C-2)

목표: 핵심 KPI 카드(속도·yaw·경고·연결상태)를 양 플랫폼 템플릿으로 렌더한다.

| ID | 항목 | 산출물 | 완료 기준 |
|---|---|---|---|
| C2-1 | CarPlay Swift 네이티브 모듈 — CPInformationTemplate 핵심 카드 | `mobile/ios/CarPlayModule.swift` | Simulator에서 카드 렌더 확인 |
| C2-2 | Android Auto Kotlin 모듈 — MessageTemplate/ListTemplate 핵심 카드 | `mobile/android/AutoModule.kt` | DHU 에뮬레이터에서 카드 렌더 확인 |
| C2-3 | React Native Bridge: WS 상태 → 네이티브 모듈 emit | Bridge 모듈 + JS 이벤트 훅 | 실시간 데이터 반영 확인 |
| C2-4 | 투영 연결 상태 분리 모니터링 (Projection vs WS) | 상태 표시 UI (모바일 화면) | 양 상태가 독립 표시됨 |

Gate C-2 Pass Criteria:
- 양 플랫폼 Simulator/DHU에서 속도·yaw·경고·연결상태 카드 렌더 확인
- WS 데이터 변경 시 투영 화면 1초 내 갱신
- 투영 연결 상태와 서버 WS 상태가 독립적으로 표시

### Phase C-3: 폴백 및 안정화 (Gate C-3 / platform-matrix Gate C)

목표: 투영 단절 시 모바일 화면 자동 복귀, 실기기 검증 완료.

| ID | 항목 | 산출물 | 완료 기준 |
|---|---|---|---|
| C3-1 | 투영 단절 → 모바일 폴백 상태머신 | JS 상태머신 + 네이티브 이벤트 연동 | 단절 후 5초 내 모바일 화면 자동 복귀 |
| C3-2 | 실기기 검증 (iPhone + CarPlay 호환 차량/헤드유닛) | 검증 결과 리포트 | 핵심 카드 렌더 + 폴백 동작 확인 |
| C3-3 | 실기기 검증 (Android + Android Auto 호환 차량/헤드유닛) | 검증 결과 리포트 | 핵심 카드 렌더 + 폴백 동작 확인 |
| C3-4 | 심사/배포 패키징 (개인정보 고지, 위치 권한 목적 문구) | 앱 심사 제출 패키지 | 심사 통과 또는 거절 사유 해소 |

Gate C-3 Pass Criteria (= platform-matrix Gate C):
- CarPlay / Android Auto 양쪽에서 핵심 KPI 카드 렌더 및 경고 표시 확인
- 투영 연결 단절 시 5초 내 모바일 화면 자동 폴백
- `docs/platform-matrix.md` § Gate C 체크리스트 전 항목 통과

## Consequences

- Positive:
  - ADR-0001 결정을 번복하지 않고 Phase C 진입 가능
  - 투영 전용 네이티브 모듈을 분리하여 플랫폼 정책 변화에 국소적으로 대응 가능
  - JS 상태 레이어의 단위 테스트를 투영 화면과 무관하게 유지 가능
- Negative:
  - CarPlay entitlement 승인 대기(수 주~수 개월)가 Gate C-1 블로커
  - iOS Swift + Android Kotlin 브리지 모듈 추가로 CI/CD 파이프라인 복잡도 증가
  - CPTemplate API 변경 시 Swift 모듈 독립 업데이트 필요

## Revisit Triggers

- CarPlay entitlement 신청이 반복 거절될 경우 (→ Option B 또는 제3자 SDK 재검토)
- CPTemplate / Car App Library 신규 버전에서 브리지 방식이 지원 불가해질 경우
- 팀의 Swift/Kotlin 네이티브 리소스가 장기 부족할 경우 (→ Option C 외부 라이브러리 재검토)

## Related Documents

- [ADR-0001: Mobile Runtime Selection](0001-mobile-runtime-selection.md)
- [Platform Implementation Matrix & Checklist](../platform-matrix.md)
- [iOS Background 30-min Report Template](../reports/ios-bg-30min-template.md)
