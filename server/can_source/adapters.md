# Adapter Extension Guide (Vector/CANape/CANoe/ATI/MATLAB)

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
- MATLAB script가 `ws://localhost:8080/ws` 또는 `POST /api/gps` 같은 endpoint로 push
- 서버는 수신값을 cache하고 프론트로 브로드캐스트
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
