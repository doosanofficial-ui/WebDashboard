# ADR-0003: Native iOS and Reliable Ingest

- Status: Accepted for implementation, release not approved
- Date: 2026-09-19
- User authorization: 사내 엔지니어 배포, iPhone 17 / iOS 26.6.2 우선,
  기존 구현 교체 가능, 목표 달성까지 자율 실행.

## Decision

iOS는 SwiftUI + Core Location + 영속 outbox + URLSession으로 구현한다.
화면 렌더와 GPS 수집/기록을 분리하고, 화면 잠금 중에도 허용된 위치 이벤트를
즉시 로컬에 저장한다. 서버 ACK를 받은 이벤트만 outbox에서 제거한다.
기존 React Native 구현은 이행 기간에 보존하며 새 iOS 앱의 필수 빌드 의존성에서 제외한다.

Windows 서버는 Python/FastAPI를 유지하고 SQLite WAL journal을 수신 기록의
원본으로 사용한다. CSV는 journal에서 내보낼 수 있어야 한다.
웹 대시보드는 CAN 10Hz 구독과 지도/로드뷰 UI에 재사용한다.
기존 v1 WebSocket CAN 프레임은 유지하고 신뢰성 있는 uplink를 별도 버전으로 추가한다.

## Alternatives

1. RN 업그레이드 + native bridge 유지: UI 공통화 이점은 있으나
   백그라운드 기록/전송을 네이티브로 내려야 하므로 현재 요구에서는 계층이 늘어난다.
2. Swift 네이티브 iOS + 기존 웹/서버: 우선 기기의 위치 수명주기, Keychain,
   background networking, CarPlay를 직접 제어한다. Android UI는 별도 구현 비용이 있다.
3. PWA만 유지: 화면 잠금 수집을 보장하는 제품 요건을 충족하지 못한다.

2번을 선택한다. 화면 OFF 중 CAN 화면을 10Hz로 렌더하는 것은 목표가 아니며,
서버 CAN 기록 지속과 모바일 위치 수집/전송의 연속성이 목표다.

## Uplink Contract

POST /api/v2/ingest

```json
{
  "v": 2,
  "client_id": "device-1",
  "events": [{
    "id": "5c6a7f61-24c4-4ed9-8216-5fd0ffde1001",
    "type": "GPS",
    "captured_t": 1700000000.0,
    "data": {"lat": 37.0, "lon": 127.0, "spd": null, "hdg": null, "acc": 5.0, "alt": null},
    "meta": {"bg_state": "background"}
  }]
}
```

- Maximum batch 200 events, request body <= 256 KiB.
- client_id: ASCII identifier, 1..128 characters; event id: UUID.
- GPS lat/lon are finite numbers in geographic range, not booleans or strings.
- spd/acc are nonnegative finite numbers or null; hdg is [0,360) or null;
  alt is finite or null. Unknown stays null.
- captured_t is the original positive epoch seconds and is never refreshed for replay.
- MARK uses data.note (<= 500 characters). Lifecycle uses type STATE with
  data.state in foreground/background/stopped. No arbitrary event execution.
- meta is optional with only bg_state/os/app_ver/device fields and bounded strings.
- Batch validation is atomic. Invalid item rejects the batch before any record is written.
- Unique key is (client_id, event id). Identical replay acknowledges existing durable data;
  a reused ID with different content returns 409 and rolls back the whole batch.
- ACK body: v=2, client_id, acked UUID list. ACK is emitted only after SQLite commit.
- Journal persists captured_t and received_t separately; received_t of original event
  remains unchanged on retry. Database lock/disk failure returns no success ACK.
- Device pairing/TLS and the HTTP handler are mandatory follow-up integration gates.

## Implementation Order

1. server/ingest.py + server/tests/test_ingest.py: bounded validation,
   SQLite persistence, atomic replay/conflict/rollback tests, CSV export.
2. FastAPI ingestion handler: body size, pairing, durable ACK and error status/body
   regression tests over actual HTTP. Protect existing CAN subscribers from slow clients.
3. mobile-ios/TelemetryCore: Codable event model and durable outbox,
   Swift package tests for restart/partial ACK/network error ordering.
4. iOS app target: Core Location capture, background file access, URLSession upload,
   native dashboard and known capability/permission state. Build on supported Xcode.
5. Windows installation, device pairing, map credentials and real adapter.
6. 30-minute screen-lock / reconnect / MARK / 1-hour endurance evidence.
7. CarPlay entitlement/category validation and templates; Android native collection.

## Completion Gates

Automated kernel tests do not prove iOS background behavior or commercial readiness.
Xcode/iPhone/Windows/CAN hardware and CarPlay platform approval remain required evidence.
The full checklist is docs/production-plan.md. Existing implementation is preserved
until data-contract and UI migration tests show the replacement works.
