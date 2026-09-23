# Adapter Extension Guide (Vector/CANape/CANoe/ATI/MATLAB/OBD)

MVP는 `DummyCANSource`만 포함합니다. 실차 신호 연동은 `CANSource` 구현체를 교체하는 방식으로 확장합니다.

## 공통 인터페이스
- 파일: `server/can_source/base.py`
- 계약: `next_frame() -> dict[str, float]`
- 반환 키는 기본적으로 `ws_fl/ws_fr/ws_rl/ws_rr/yaw/ax/ay`를 권장합니다.

## 확장 옵션

### A) CANoe -> UDP/TCP bridge -> server adapter
- CANoe 측 CAPL/Measurement 설정으로 신호를 UDP/TCP JSON/CSV line으로 송출
- 서버에서 별도 async receiver task로 수신 후 최신 신호 캐시
- `CANSource.next_frame()`는 캐시를 읽어 반환
- 장점: 실시간성 좋고 구조 단순
- 리스크: CANoe 프로젝트마다 export 설정 재작업 필요

### B) CANape measurement export/DAQ external feed -> server adapter
- CANape에서 외부 송신(가능한 plugin/API/export) 경로를 사용해 신호 전달
- 전달 포맷을 고정(JSON, CSV line, ZeroMQ 등)하고 adapter에서 decode
- 장점: 기존 CANape 측정 체인 재사용 가능
- 리스크: 라이선스/버전별 외부 export 가능 범위 차이

### C) MATLAB 2022b -> local push -> server
- MATLAB에서 Vector/PEAK/로그를 읽어 신호 계산
- MATLAB에서 전용 CAN bridge 계약/수신기를 구현한 뒤 신호를 push
- 현재 `/ws` uplink와 `/api/gps`는 CAN ingest endpoint가 아니므로 사용하지 않음
- 새 adapter는 수신값을 cache하고 `next_frame()`에서 최신 snapshot을 반환
- 장점: 신호 가공 알고리즘을 MATLAB에서 바로 유지 가능
- 리스크: 실시간 처리 시 MATLAB 실행/IPC 지연 관리 필요

### D) ATI Vision (로그 기반 후처리)
- 실시간 feed는 환경 의존성이 높아 MVP 범위 밖
- `.rec/.mat` 등 로그를 오프라인 변환해 시계열 재생(replay adapter)으로 사용 가능
- 이벤트 동기화 시 기준 timestamp epoch/monotonic 정합 필요

## 체크리스트 (사내 환경 확인용)
- Vector 드라이버 버전과 VN1640A 인식 여부
- CANoe/CANape 라이선스에서 외부 송신/automation/API 사용 가능 여부
- 사용 가능한 SDK/API 문서 접근 권한
- 방화벽/백신이 localhost/UDP/TCP loopback을 차단하는지
- 타임스탬프 기준(UTC epoch vs monotonic) 통일 여부
- 단위/스케일(km/h, m/s, deg/s, m/s^2) 합의 여부
- 10Hz 이상 송신 시 CPU/지연 측정 결과

## E) NANICAR ELM327-BT4N -> native iOS / Windows bridge

- 실제 보유 장비 라벨: ELM327-BT4N, 12V. 목표 차량: 현대 싼타페 MX5 HEV(연식 미확인).
- iPhone 17 / iOS 27 Core Bluetooth가 우선. Windows는 확인된 BLE GATT 또는 serial로 수신.
- GATT UUID/특성은 실물에서 발견·검증하며 유사 ELM 장비의 값을 복사해 확정하지 않음.
- Mode 01 지원 PID부터 읽고, OBD vehicle speed를 `ws_fl/fr/rl/rr`로 복제하지 않음.
- OBD 수집 작업은 `next_frame()`의 동기식 장비 질의가 아니라 별도 receiver/cache 경로.
- 현재 float snapshot만으로는 PID별 sample age/quality를 보존할 수 없으므로,
  source/time/quality 계약과 OBD 전용 로그/UI를 함께 구현한 뒤 연결한다.
- 현재 v2 GPS/MARK/STATE ingest는 OBD를 지원하지 않음. 전용 버전 계약과 ACK 검증이 선행 조건.
- 설계와 실물 완료 기준: [ADR-0004](../../docs/adr/0004-obd-bt4n-integration.md),
  [호환 실행표](../../docs/reports/obd-bt4n-compatibility.md).
