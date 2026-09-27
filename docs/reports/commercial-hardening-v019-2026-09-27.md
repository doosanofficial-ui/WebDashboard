# Commercial Hardening v0.19 Checkpoint

Date: 2026-09-27

## Functional change

The legacy v1 GPS/MARK uplink now has an explicit production authentication
mode. Set `INGEST_TOKEN` and `REQUIRE_LEGACY_UPLINK_AUTH=1` to require:

- Bearer authorization on `POST /api/gps` and `POST /api/event`;
- a first WebSocket text frame `{ "v": 1, "type": "auth", "token": "..." }`;
- browser session-token storage only in `sessionStorage`, never in the URL or
  persistent local storage.

The default remains disabled for the local MVP so existing loopback testing is
not silently broken. Native durable v2 ingestion remains Bearer-authenticated.

## Verification

| Area | Result | Evidence |
| --- | --- | --- |
| Legacy HTTP/WS auth | PASS | `test_legacy_auth.py` covers Bearer and WebSocket handshake |
| Server regression suite | PASS | 80 tests, 0 failures |
| Client auth handshake | PASS | `scripts/tests/ws-auth.test.mjs` |
| GPS/service worker suites | PASS | 28 + 8 tests |
| Python compile | PASS | server source and CAN sources |
| Native app build | PASS | `/tmp/telemetry-ios-verify.HCMfpo`; `BUILD SUCCEEDED` |
| Release identity | v0.19.0 build 10 | `release.json`, `mobile-ios/project.yml` |

## Remaining gates

- Xcode 27/iOS 27 SDK and physical iPhone 17 runtime evidence remain external.
- Real VN1640A/CANoe/BT4N/Santa Fe MX5 HEV measurements remain unverified.
- CarPlay entitlement and projection runtime remain unverified.
- Windows clean-machine installation, TLS trust, firewall, upgrade/rollback,
  and 30-minute background measurements remain required.
