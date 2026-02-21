# ADR-0001: Mobile Runtime Selection for Background Telemetry and Projection

- Status: Accepted
- Date: 2026-02-21
- Decision Drivers:
  - iOS/Android background GPS uplink 안정성
  - CarPlay / Android Auto 확장 가능성
  - 현재 WebDashboard(Web + FastAPI) 자산 재사용률
  - 팀의 구현/운영 복잡도와 릴리스 속도

## Context
- 현재 MVP는 Web(PWA) 기반으로 foreground 텔레메트리 표시에 최적화되어 있다.
- 다음 단계는 background GPS uplink와 차량 투영(CarPlay/Android Auto)이다.
- 이 두 요구사항은 웹 단독으로 제약이 크므로 모바일 런타임 선택이 필요하다.

## Options

### Option A: React Native + Native Bridge (권장)
- 설명:
  - 공통 UI/상태 코드는 JS/TS로 유지
  - background location, CarPlay/Android Auto는 네이티브 브리지 모듈로 처리
- 장점:
  - 기존 웹 로직(데이터 모델/상태머신) 재사용이 비교적 쉽다
  - 팀 내 웹 역량 활용 가능
  - 기능 확장 시 native escape hatch가 명확하다
- 단점:
  - 브리지 유지보수 비용 존재
  - 투영 UI는 사실상 네이티브 작업이 필요

### Option B: Flutter + Platform Channels
- 설명:
  - 단일 코드베이스로 모바일 UI를 구성, 플랫폼 특화 기능은 채널로 연동
- 장점:
  - UI 일관성 확보가 쉽다
  - 성능/렌더링 안정성이 높다
- 단점:
  - 현재 웹 코드 재사용률이 낮다
  - 팀 러닝 커브와 빌드 파이프라인 전환 비용이 크다

### Option C: Full Native (Swift + Kotlin)
- 설명:
  - iOS/Android를 각각 네이티브로 구현
- 장점:
  - background/CarPlay/Android Auto 대응력이 가장 높다
  - 플랫폼 정책 대응과 디버깅이 직접적이다
- 단점:
  - 개발/유지보수 비용이 가장 높다
  - 공통 코드 비율이 낮다

## Recommendation
- 기본 권고: **Option A (React Native + Native Bridge)**  
  - 이유:
    - 현재 웹 기반 자산을 최대한 재사용하면서도
    - background 및 projection의 필수 네이티브 포인트를 안전하게 수용 가능
    - 초기 속도와 장기 확장성의 균형이 가장 좋다

## Decision
- 채택안: **Option A (React Native + Native Bridge)**
- 결정일: 2026-02-21
- 결정자: Product/Engineering
- 근거:
  - WebDashboard의 기존 JS 자산을 최대 재사용할 수 있음
  - Background GPS 및 Projection 확장을 위한 네이티브 escape hatch 확보 가능
  - 초기 납기와 장기 유지보수 균형이 가장 양호함

## Consequences
- Positive:
  - WebDashboard 프로토콜/상태 관리 자산을 모바일로 이전하기 쉽다
  - 필요 시 네이티브 모듈만 국소적으로 강화 가능
- Negative:
  - 브리지 계층(권한, 위치, projection) 테스트 매트릭스가 늘어난다
  - CI/CD 파이프라인(모바일 빌드 서명 포함) 추가 설계가 필요

## Initial Execution Plan
1. 선택 런타임 확정 및 리포 구조 정의(`mobile/` 신규)
2. Background GPS 최소 기능 PoC(화면 OFF 30분 uplink)
3. Store-and-forward 큐와 서버 스키마 확장
4. Projection PoC(핵심 카드만 렌더)

## Acceptance Criteria for This ADR
- [x] 팀이 Option A/B/C 중 1개를 공식 채택한다.
- [x] 채택/기각 사유와 재검토 트리거를 문서에 확정한다.

## Revisit Triggers
- Projection 정책/엔타이틀먼트로 인해 브리지 접근이 과도하게 복잡해질 때
- Background 누락률 목표를 반복적으로 충족하지 못할 때
- 팀의 네이티브 리소스 가용성이 크게 바뀔 때
